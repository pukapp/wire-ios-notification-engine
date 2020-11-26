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
        self.isReadyFetch = true
    }

    public override func nextRequest() -> ZMTransportRequest? {
        guard isReadyFetch else {return nil}
        self.isReadyFetch = false
        return streamSync.nextRequest()
    }
    
    public var requestGenerators: [ZMRequestGenerator] {
        return [self]
    }
    
    public var isReadyFetch: Bool = false {
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
                
        exLog.info("start process events, events count is \(events.count)")
        
        for event in decryptedUpdateEvents {
            
            exLog.info("current process event is \(String(describing: event.uuid)) eventType: \(event.type.rawValue)")
            
            self.process(event: event, moc: moc)
            
            exLog.info("finished process event: \(String(describing: event.uuid?.transportString())) eventType: \(event.type.rawValue)")
            
            moc.tearDown()
            
            exLog.info("moc tearDown")
            
            moc.setup(sharedContainerURL: self.sharedContainerURL, accountUUID: self.accountIdentifier)
        }
        moc.tearDown()
        exLog.info("already processed all events, set isReadyFetch true after processed all events")
        self.isReadyFetch = true
    }
    
    
    func process(event: ZMUpdateEvent, moc: NSManagedObjectContext) {
        
        exLog.info("begin process event: \(String(describing: event.uuid)) \(event.type.rawValue)")
        
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
            exLog.info("moc.save()")
            try moc.save()
        } catch {
            print("save error \(error)")
        }
        exLog.info("context save success")
        
        exLog.info("prepare update last eventId: \(String(describing: event.uuid?.transportString()))")
        
        //处理事件后更新id
        let userDefault = AppGroupInfo.sharedUserDefaults
        
        exLog.info("begin update last eventid with userdefault: \(userDefault) key: \(lastUpdateEventIDKey) accountIdentifier: \(self.accountIdentifier.transportString())")
        
        userDefault.set(event.uuid?.transportString(), forKey: lastUpdateEventIDKey + self.accountIdentifier.transportString())
        
        exLog.info("update last eventid success")
        
        // 释放
        transcoders.forEach { (ob) in
            if let o = ob as? TearDownCapable {
                o.tearDown()
            }
        }
        
        exLog.info("free memory eventid: \(String(describing: event.uuid?.transportString()))")
    }
    
}


