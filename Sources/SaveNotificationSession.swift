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

public class SaveNotificationSession {
    
    public let transportSession: ZMTransportSession
    
    private var syncMoc: NSManagedObjectContext!
        
    private let operationLoop: RequestGeneratingOperationLoop
    
    private let saveNotificationPersistence: ContextDidSaveNotificationPersistence
    
    private let sharedContainerURL: URL
    
    private let accountIdentifier: UUID
    
    private var strategy: PushSaveNotificationStrategy
    
    public var isReadyFetch: Bool {
        return self.strategy.isReadyFetch
    }
        
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
                            token: ZMAccessToken?) throws {
        let sharedContainerURL = FileManager.sharedContainerDirectory(for: applicationGroupIdentifier)
        let accountDirectory = StorageStack.accountFolder(accountIdentifier: accountIdentifier, applicationContainer: sharedContainerURL)
        let storeFile = accountDirectory.appendingPersistentStoreLocation()
        let model = NSManagedObjectModel.loadModel()
        let psc = NSPersistentStoreCoordinator(managedObjectModel: model)
        let options = NSPersistentStoreCoordinator.persistentStoreOptions(supportsMigration: false)
        try psc.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeFile, options: options)
        let moc = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        moc.performAndWait {
            moc.persistentStoreCoordinator = psc
            moc.setup(sharedContainerURL: sharedContainerURL, accountUUID: accountIdentifier)
            moc.stalenessInterval = -1
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
            accountIdentifier: accountIdentifier)
    }
    
    public convenience init(moc: NSManagedObjectContext,
                            transportSession: ZMTransportSession,
                            accountContainer: URL,
                            delegate: NotificationSessionDelegate?,
                            sharedContainerURL: URL,
                            accountIdentifier: UUID) throws {
        

        let stage = PushSaveNotificationStrategy(withManagedObjectContext: moc, sharedContainerURL: sharedContainerURL, accountIdentifier: accountIdentifier)
        
        let requestGeneratorStore = RequestGeneratorStore(strategies: [stage])
        
        let operationLoop = RequestGeneratingOperationLoop(
            callBackQueue: .main,
            requestGeneratorStore: requestGeneratorStore,
            transportSession: transportSession,
            moc:moc,
            type: .extensionStreamNewRequest
        )
        
        try self.init(
            moc: moc,
            transportSession: transportSession,
            operationLoop: operationLoop,
            sharedContainerURL: sharedContainerURL,
            accountIdentifier: accountIdentifier,
            stage: stage
        )
        
    }
    
    internal init(moc: NSManagedObjectContext,
                  transportSession: ZMTransportSession,
                  operationLoop: RequestGeneratingOperationLoop,
                  sharedContainerURL: URL,
                  accountIdentifier: UUID,
                  stage: PushSaveNotificationStrategy
        ) throws {
        
        self.syncMoc = moc
        self.transportSession = transportSession
        self.operationLoop = operationLoop
        self.sharedContainerURL = sharedContainerURL
        self.accountIdentifier = accountIdentifier
        self.strategy = stage
        let accountContainer = StorageStack.accountFolder(accountIdentifier: accountIdentifier, applicationContainer: sharedContainerURL)
        self.saveNotificationPersistence = ContextDidSaveNotificationPersistence(accountContainer: accountContainer)
        NotificationCenter.default.addObserver(
        self,
        selector: #selector(SaveNotificationSession.contextDidSave(_:)),
        name:.NSManagedObjectContextDidSave,
        object: moc)
    }

    deinit {
        print("NotificationSession deinit")
        transportSession.reachability.tearDown()
        transportSession.tearDown()
    }
}

extension SaveNotificationSession {
    @objc func contextDidSave(_ note: Notification){
        self.saveNotificationPersistence.add(note)
    }
}

extension SaveNotificationSession {
    
    public func setupWithToken(token: ZMAccessToken?) {
        self.transportSession.accessToken = token
        self.syncMoc.performGroupedAndWait{ [unowned self] _  in
            self.syncMoc.setup(sharedContainerURL: self.sharedContainerURL, accountUUID: self.accountIdentifier)
        }
    }
    
}
