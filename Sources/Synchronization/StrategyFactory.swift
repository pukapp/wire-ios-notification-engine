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
import WireSyncEngine

class StrategyFactory {

    unowned let syncContext: NSManagedObjectContext
    private(set) var strategies = [AnyObject]()
    private(set) weak var delegate: NotificationSessionDelegate?
    
    private(set) var sharedContainerURL: URL
    private(set) var accountIdentifier: UUID

    private var tornDown = false
    private var eventId: String
    private var userDefault: UserDefaults

    init(syncContext: NSManagedObjectContext,
         notificationSessionDelegate: NotificationSessionDelegate?,
         sharedContainerURL: URL,
         accountIdentifier: UUID,
         eventId: String,
         userDefault: UserDefaults) {
        self.syncContext = syncContext
        self.delegate = notificationSessionDelegate
        self.sharedContainerURL = sharedContainerURL
        self.accountIdentifier = accountIdentifier
        self.eventId = eventId
        self.userDefault = userDefault
        self.strategies = createStrategies()
    }

    deinit {
        print("StrategyFactory deinit")
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
                                        notificationSessionDelegate: delegate,
                                        sharedContainerURL: sharedContainerURL,
                                        accountIdentifier: accountIdentifier,
                                        eventId: self.eventId,
                                        userDefault: self.userDefault)
    }
}
