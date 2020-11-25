//
// Wire
// Copyright (C) 2020 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

import WireRequestStrategy
import WireSyncEngine

private var exLog = ExLog(tag: "PushSaveNotificationStrategy")

public class PushSaveNotificationStrategy: AbstractRequestStrategy, ZMRequestGenerator, ZMRequestGeneratorSource {
    
    var streamSync: NotificationStreamSync!
    public var sharedContainerURL: URL
    public var accountIdentifier: UUID
    public var eventDecrypter: EventDecrypter!

    private weak var eventProcessor: UpdateEventProcessor!
    private var moc: NSManagedObjectContext?
    
    public init(withManagedObjectContext managedObjectContext: NSManagedObjectContext,
                sharedContainerURL: URL,
                accountIdentifier: UUID) {
        
        self.sharedContainerURL = sharedContainerURL
        self.accountIdentifier = accountIdentifier
        super.init(withManagedObjectContext: managedObjectContext,
                   applicationStatus: nil)
        streamSync = NotificationStreamSync(moc: managedObjectContext, delegate: self, accountid: accountIdentifier)
        streamSync.fetchNotificationSync.readyForNextRequest()
        self.eventProcessor = self
        self.moc = managedObjectContext
        self.eventDecrypter = EventDecrypter(syncMOC: managedObjectContext)
        isReadyFetch = true
    }

    public override func nextRequest() -> ZMTransportRequest? {
        guard isReadyFetch else {return nil}
        return streamSync.nextRequest()
    }
    
    public var requestGenerators: [ZMRequestGenerator] {
        return [self]
    }
    
    private var isReadyFetch: Bool = false {
        didSet {
            if isReadyFetch {
                self.streamSync.fetchNotificationSync.readyForNextRequest()
            }
        }
    }
    
    deinit {
        print("PushSaveNotificationStrategy deinit")
    }
    
}

extension PushSaveNotificationStrategy: NotificationStreamSyncDelegate {
    
    public func fetchedEvents(_ events: [ZMUpdateEvent]) {
        exLog.info("NotificationStreamSync fetchedEvent \(events.count)")
        eventProcessor.processUpdateEvents(events)
    }
    
    public func failedFetchingEvents() {
        //no op
    }
}

extension PushSaveNotificationStrategy: UpdateEventProcessor {

    @objc(processUpdateEvents:)
    public func processUpdateEvents(_ updateEvents: [ZMUpdateEvent]) {
        guard let moc = self.moc else {return}
        self.processEvents(updateEvents, moc: moc)
    }
    
    @objc(decryptUpdateEventsAndGenerateNotification:)
    public func decryptUpdateEventsAndGenerateNotification(_ updateEvents: [ZMUpdateEvent]) {
        // no op
    }
    
    public func storeAndProcessUpdateEvents(_ updateEvents: [ZMUpdateEvent], ignoreBuffer: Bool) {
        // Events will be processed in the foreground
    }
    
    func processEvents(_ events: [ZMUpdateEvent], moc: NSManagedObjectContext) {
        
        moc.setup(sharedContainerURL: self.sharedContainerURL, accountUUID: self.accountIdentifier)
        
        let decryptedUpdateEvents = eventDecrypter.decryptEvents(events)
        
        let lock = DispatchSemaphore(value: 1)
        
        exLog.info("start process events \(events.count)")
        
        for event in decryptedUpdateEvents {
            exLog.info("current wait event is \(String(describing: event.uuid)) \(event.type.rawValue)")
            exLog.info("wait lock \(String(describing: event.uuid)) \(event.type.rawValue)")
            lock.wait()
            exLog.info("get lock \(String(describing: event.uuid)) \(event.type.rawValue)")
            exLog.info("current process event is \(String(describing: event.uuid)) \(event.type.rawValue)")
            
            self.process(event: event, moc: moc)
            
            moc.tearDown()
            
            moc.setup(sharedContainerURL: self.sharedContainerURL, accountUUID: self.accountIdentifier)
            
            DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + 0.3) {
                lock.signal()
                exLog.info("release lock \(String(describing: event.uuid)) \(event.type.rawValue)")
            }
        }
        exLog.info("already processed all events")
        DispatchQueue.global().asyncAfter(deadline: DispatchTime.now() + 1) {
            moc.tearDown()
            self.isReadyFetch = true
            exLog.info("set isReadyFetch true after processed all events")
        }
    }
    
    
    func process(event: ZMUpdateEvent, moc: NSManagedObjectContext) {
        
        let conversationTranscoder = ZMConversationTranscoder(managedObjectContext: moc, applicationStatus: nil, localNotificationDispatcher: nil, syncStatus: nil)
        let connectionTranscoder = ZMConnectionTranscoder(managedObjectContext: moc, applicationStatus: nil, syncStatus: nil)
        let userPropertyStrategy = UserPropertyRequestStrategy(withManagedObjectContext: moc, applicationStatus: nil)
        let pushTokenStrategy = PushTokenStrategy(withManagedObjectContext: moc, applicationStatus: nil, analytics: nil)
        let userTransCoder = ZMUserTranscoder(managedObjectContext: moc, applicationStatus: nil, syncStatus: nil)
        let userDisableSendMsgStrategy = UserDisableSendMsgStatusStrategy(context: moc, dispatcher: nil)
        let userclientStrategy = UserClientRequestStrategy(clientRegistrationStatus: nil, clientUpdateStatus: nil, context: moc, userKeysStore: nil)
        let clientMessageTranscoder = ClientMessageTranscoder(in: moc, localNotificationDispatcher: nil, applicationStatus: nil)
        let transcoders = [clientMessageTranscoder, conversationTranscoder, connectionTranscoder, userPropertyStrategy, userclientStrategy, pushTokenStrategy, userTransCoder, userDisableSendMsgStrategy]
        transcoders.forEach { (ob) in
            if let o = ob as? ZMEventConsumer {
                o.processEvents([event], liveEvents: true, prefetchResult: nil)
            }
        }
        do {
            try moc.save()
        } catch {
            print("save error \(error)")
        }
        //处理事件后更新id
        let userDefault = AppGroupInfo.sharedUserDefaults
        userDefault.set(event.uuid?.transportString(), forKey: lastUpdateEventIDKey + self.accountIdentifier.transportString())
        // 释放
        transcoders.forEach { (ob) in
            if let o = ob as? TearDownCapable {
                o.tearDown()
            }
        }
    }
    
}


