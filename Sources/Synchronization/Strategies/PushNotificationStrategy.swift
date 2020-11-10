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

public protocol NotificationSessionDelegate: class {
    func modifyNotification(_ alert: ClientNotification)
}

public struct ClientNotification {
    public var title: String
    public var body: String
    public var categoryIdentifier: String
    public var userInfo: [AnyHashable : Any]?
    public var sound: UNNotificationSound?
    public var threadIdentifier: String?
    public var conversationID: String?
    
    public var isInValided: Bool {
        return title.count == 0 && body.count == 0 && categoryIdentifier.count == 0
    }
}

private var exLog = ExLog(tag: "NotificationExtension")

public final class PushNotificationStrategy: AbstractRequestStrategy, ZMRequestGeneratorSource {
    
    var sync: NotificationSingleSync!
    private weak var eventProcessor: UpdateEventProcessor!
    private weak var delegate: NotificationSessionDelegate?
    private unowned var moc: NSManagedObjectContext!
    
    var eventDecrypter: EventDecrypter!
    private var eventId: String
    private var accountIdentifier: UUID
    
    public init(withManagedObjectContext managedObjectContext: NSManagedObjectContext,
                notificationSessionDelegate: NotificationSessionDelegate?,
                sharedContainerURL: URL,
                accountIdentifier: UUID,
                eventId: String,
                hugeConvId: String? = nil) {
        
        self.eventId = eventId
        self.accountIdentifier = accountIdentifier
        super.init(withManagedObjectContext: managedObjectContext,
                   applicationStatus: nil)
        
        sync = NotificationSingleSync(moc: managedObjectContext, delegate: self, eventId: eventId, hugeConvId: hugeConvId)
        self.eventProcessor = self
        self.delegate = notificationSessionDelegate
        self.moc = managedObjectContext
        self.eventDecrypter = EventDecrypter(syncMOC: managedObjectContext)
    }
    
    public override func nextRequestIfAllowed() -> ZMTransportRequest? {
        return requestGenerators.nextRequest()
    }
    
    public override func nextRequest() -> ZMTransportRequest? {
        return requestGenerators.nextRequest()
    }
    
    public var requestGenerators: [ZMRequestGenerator] {
        return [sync]
    }
    
    deinit {
        print("PushNotificationStrategy deinit")
    }
    
}

extension PushNotificationStrategy: NotificationSingleSyncDelegate {
    
    public func fetchedEvent(_ event: ZMUpdateEvent) {
        exLog.info("pushNotificationStrategy fetchedEvent \(event.debugInformation)")
        eventProcessor.decryptUpdateEventsAndGenerateNotification([event])
    }
    
    public func failedFetchingEvents() {
        
    }
}

extension PushNotificationStrategy: UpdateEventProcessor {
    
    public func processUpdateEvents(_ updateEvents: [ZMUpdateEvent]) {
        
    }
    
    public func decryptUpdateEventsAndGenerateNotification(_ updateEvents: [ZMUpdateEvent]) {
        exLog.info("ready for decrypt event \(String(describing: updateEvents.first?.uuid?.transportString()))")
        let decryptedUpdateEvents = eventDecrypter.decryptEvents(updateEvents)
        exLog.info("already decrypt event \(String(describing: decryptedUpdateEvents.first?.uuid?.transportString()))")
        let localNotifications = self.convertToLocalNotifications(decryptedUpdateEvents, moc: self.moc)
        exLog.info("convertToLocalNotifications \(String(describing: localNotifications.first.debugDescription))")
        var alert = ClientNotification(title: "", body: "", categoryIdentifier: "")
        if let notification = localNotifications.first {
            alert.title = notification.title ?? ""
            alert.body = notification.body
            alert.categoryIdentifier = notification.category
            alert.sound = UNNotificationSound(named: convertToUNNotificationSoundName(notification.sound.name))
            alert.userInfo = notification.userInfo?.storage
            // only group non ephemeral messages
            if let conversationID = notification.conversationID {
                switch notification.type {
                case .message(.ephemeral): break
                default: alert.conversationID = conversationID.transportString()
                }
            }
            
        }
        // The notification service extension API doesn't support generating multiple user notifications. In this case, the body text will be replaced in the UI project.
        self.delegate?.modifyNotification(alert)
    }
    
    public func storeAndProcessUpdateEvents(_ updateEvents: [ZMUpdateEvent], ignoreBuffer: Bool) {
        // Events will be processed in the foreground
    }
    
}

extension PushNotificationStrategy {
    
    private func convertToLocalNotifications(_ events: [ZMUpdateEvent], moc: NSManagedObjectContext) -> [ZMLocalNotification] {
        return events.compactMap { event in
            var conversation: ZMConversation?
            if let conversationID = event.conversationUUID() {
                exLog.info("convertToLocalNotifications conversationID: \(conversationID) before fetch conversation from coredata")
                conversation = ZMConversation.init(noRowCacheWithRemoteID: conversationID, createIfNeeded: false, in: moc)
                exLog.info("convertToLocalNotifications conversationID: \(conversationID) after fetch conversation from coredata")
            }
            guard event.senderUUID() != self.accountIdentifier else {return nil}
            return ZMLocalNotification(noticationEvent: event, conversation: conversation, managedObjectContext: moc)
        }
    }
}
