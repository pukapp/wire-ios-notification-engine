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

import Foundation
import WireRequestStrategy
import WireTransport.ZMRequestCancellation
import WireLinkPreview

class StrategyFactory {

    unowned let syncContext: NSManagedObjectContext
    let applicationStatus: ApplicationStatus
    let pushNotificationStatus: PushNotificationStatus
    let notificationsTracker: NotificationsTracker?
    private(set) var strategies = [AnyObject]()
    public var delegate: UpdateEventsDelegate?
    
    private(set) var sharedContainerURL: URL
    private(set) var accountIdentifier: UUID

    private var tornDown = false

    init(syncContext: NSManagedObjectContext,
         applicationStatus: ApplicationStatus,
         pushNotificationStatus: PushNotificationStatus,
         notificationsTracker: NotificationsTracker?,
         sharedContainerURL: URL,
         accountIdentifier: UUID) {
        self.syncContext = syncContext
        self.applicationStatus = applicationStatus
        self.pushNotificationStatus = pushNotificationStatus
        self.notificationsTracker = notificationsTracker
        
        self.sharedContainerURL = sharedContainerURL
        self.accountIdentifier = accountIdentifier
        
        self.strategies = createStrategies()
    }

    deinit {
        precondition(tornDown, "Need to call `tearDown` before `deinit`")
    }

    func tearDown() {
        strategies.forEach {
            if $0.responds(to: #selector(ZMObjectSyncStrategy.tearDown)) {
                ($0 as? ZMObjectSyncStrategy)?.tearDown()
            }
        }
        tornDown = true
    }

    private func createStrategies() -> [AnyObject] {
        return [
            
            createPushNotificationStrategy()
        ]
    }
    
    private func createPushNotificationStrategy() -> PushNotificationStrategy {
        return PushNotificationStrategy(withManagedObjectContext: syncContext,
                                        applicationStatus: applicationStatus,
                                        pushNotificationStatus: pushNotificationStatus,
                                        notificationsTracker: notificationsTracker,
                                        updateEventsDelegate: self,
                                        sharedContainerURL: sharedContainerURL,
                                        accountIdentifier: accountIdentifier,
                                        syncMOC: syncContext
                                        
        )
    }
}



extension StrategyFactory: UpdateEventsDelegate {
    func didReceive(events: [ZMUpdateEvent], in moc: NSManagedObjectContext) {
        delegate?.didReceive(events: events, in: moc)
    }
}
