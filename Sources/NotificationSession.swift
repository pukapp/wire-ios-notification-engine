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
import WireDataModel
import WireTransport
import WireRequestStrategy
import WireLinkPreview


extension BackendEnvironmentProvider {
    func cookieStorage(for account: Account) -> ZMPersistentCookieStorage {
        let backendURL = self.backendURL.host!
        return ZMPersistentCookieStorage(forServerName: backendURL, userIdentifier: account.userIdentifier)
    }
    
    public func isAuthenticated(_ account: Account) -> Bool {
        return cookieStorage(for: account).authenticationCookieData != nil
    }
}

/// A syncing layer for the notification processing
/// - note: this is the entry point of this framework. Users of
/// the framework should create an instance as soon as possible in
/// the lifetime of the notification extension, and hold on to that session
/// for the entire lifetime.
public class NotificationSession {
    
    public let transportSession: ZMTransportSession
    
    public var syncMoc: NSManagedObjectContext!
    
    public var eventMoc: NSManagedObjectContext!
    
    private let operationLoop: RequestGeneratingOperationLoop

    private let strategyFactory: StrategyFactory
    
    private let userDefault: UserDefaults
        
    /// Initializes a new `SessionDirectory` to be used in an extension environment
    /// - parameter databaseDirectory: The `NSURL` of the shared group container
    /// - throws: `InitializationError.NeedsMigration` in case the local store needs to be
    /// migrated, which is currently only supported in the main application or `InitializationError.LoggedOut` if
    /// no user is currently logged in.
    /// - returns: The initialized session object if no error is thrown
    
    public convenience init(applicationGroupIdentifier: String,
                            accountIdentifier: UUID,
                            environment: BackendEnvironmentProvider,
                            delegate: NotificationSessionDelegate?,
                            token: ZMAccessToken?,
                            eventId: String,
                            userDefault: UserDefaults) throws {
       
        let sharedContainerURL = FileManager.sharedContainerDirectory(for: applicationGroupIdentifier)
        
        let accountDirectory = StorageStack.accountFolder(accountIdentifier: accountIdentifier, applicationContainer: sharedContainerURL)
        
        let storeFile = accountDirectory.appendingPersistentStoreLocation()
        let model = NSManagedObjectModel.loadModel()
        let psc = NSPersistentStoreCoordinator(managedObjectModel: model)
        let options = NSPersistentStoreCoordinator.persistentStoreOptions(supportsMigration: false)
        try psc.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeFile, options: options)
        let moc = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        moc.markAsSyncContext()
        moc.performAndWait {
            moc.persistentStoreCoordinator = psc
            ZMUser.selfUser(in: moc)
            moc.setupUserKeyStore(accountDirectory: accountDirectory, applicationContainer: sharedContainerURL)
        }
                
        let cookieStorage = ZMPersistentCookieStorage(forServerName: environment.backendURL.host!, userIdentifier: accountIdentifier)
        let reachabilityGroup = ZMSDispatchGroup(dispatchGroup: DispatchGroup(), label: "Sharing session reachability")!
        let serverNames = [environment.backendURL, environment.backendWSURL].compactMap { $0.host }
        let reachability = ZMReachability(serverNames: serverNames, group: reachabilityGroup)
        
        let transportSession = ZMTransportSession(
            environment: environment,
            cookieStorage: cookieStorage,
            reachability: reachability,
            initialAccessToken: token,
            applicationGroupIdentifier: applicationGroupIdentifier
        )
        
        try self.init(
            moc: moc,
            transportSession: transportSession,
            accountContainer: StorageStack.accountFolder(accountIdentifier: accountIdentifier, applicationContainer: sharedContainerURL),
            delegate: delegate,
            sharedContainerURL: sharedContainerURL,
            accountIdentifier: accountIdentifier,
            eventId: eventId,
            userDefault: userDefault)
    }
    
    internal init(moc: NSManagedObjectContext,
                  transportSession: ZMTransportSession,
                  operationLoop: RequestGeneratingOperationLoop,
                  strategyFactory: StrategyFactory,
                  userDefault: UserDefaults
        ) throws {
        
        self.syncMoc = moc
        self.transportSession = transportSession
        self.operationLoop = operationLoop
        self.strategyFactory = strategyFactory
        self.userDefault = userDefault
        
        RequestAvailableNotification.notifyNewRequestsAvailable(nil)
    }
    
    public convenience init(moc: NSManagedObjectContext,
                            transportSession: ZMTransportSession,
                            accountContainer: URL,
                            delegate: NotificationSessionDelegate?,
                            sharedContainerURL: URL,
                            accountIdentifier: UUID,
                            eventId: String,
                            userDefault: UserDefaults) throws {
        
        let strategyFactory = StrategyFactory(syncContext: moc,
                                              notificationSessionDelegate: delegate,
                                              sharedContainerURL: sharedContainerURL,
                                              accountIdentifier: accountIdentifier,
                                              eventId: eventId,
                                              userDefault: userDefault)
        
        let requestGeneratorStore = RequestGeneratorStore(strategies: strategyFactory.strategies)
        
        let operationLoop = RequestGeneratingOperationLoop(
            callBackQueue: .main,
            requestGeneratorStore: requestGeneratorStore,
            transportSession: transportSession
        )
        
        try self.init(
            moc: moc,
            transportSession: transportSession,
            operationLoop: operationLoop,
            strategyFactory: strategyFactory,
            userDefault: userDefault
        )
        
    }

    deinit {
        print("NotificationSession deinit")
        transportSession.reachability.tearDown()
        transportSession.tearDown()
        strategyFactory.tearDown()
    }
}
