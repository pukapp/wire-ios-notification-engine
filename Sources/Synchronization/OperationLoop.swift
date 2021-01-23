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
import CoreData
import WireTransport
import WireRequestStrategy

let contextWasMergedNotification = Notification.Name("zm_contextWasSaved")

private var exLog = ExLog(tag: "OperationLoop")

public class RequestGeneratorStore {

    let requestGenerators: [ZMTransportRequestGenerator]
    private var isTornDown = false

    private let strategies : [AnyObject]

    public init(strategies: [AnyObject]) {

        self.strategies = strategies

        var requestGenerators : [ZMTransportRequestGenerator] = []

        for strategy in strategies {
            if let requestGeneratorSource = strategy as? ZMRequestGeneratorSource {
                for requestGenerator in requestGeneratorSource.requestGenerators {
                    requestGenerators.append({
                        return requestGenerator.nextRequest()
                    })
                }
            }
            if let requestStrategy = strategy as? RequestStrategy {
                requestGenerators.append({
                    requestStrategy.nextRequest()
                })
            }
        }

        self.requestGenerators = requestGenerators
    }

    deinit {
        precondition(isTornDown, "Need to call `tearDown` before deallocating this object")
    }

    public func tearDown() {
        strategies.forEach {
            if $0.responds(to: #selector(ZMObjectSyncStrategy.tearDown)) {
                ($0 as? ZMObjectSyncStrategy)?.tearDown()
            }
        }

        isTornDown = true
    }

    public func nextRequest() -> ZMTransportRequest? {
        for requestGenerator in requestGenerators {
            if let request = requestGenerator() {
                return request
            }
        }

        return nil
    }
}


public class RequestGeneratorObserver {
    
    public var observedGenerator: ZMTransportRequestGenerator? = nil
    
    public func nextRequest() -> ZMTransportRequest? {
        guard let request = observedGenerator?() else { return nil }
        return request
    }
    
}

public class OperationLoop : NSObject, RequestAvailableObserver {
    
    enum ObserverType {
        case newRequest
        case msgNewRequest
        case extensionStreamNewRequest
        case extensionSingleNewRequest
    }

    typealias RequestAvailableClosure = () -> Void
    private let callBackQueue: OperationQueue
    private var tokens: [NSObjectProtocol] = []
    var requestAvailableClosure: RequestAvailableClosure?
    private var moc: NSManagedObjectContext

    init(callBackQueue: OperationQueue = .main, moc: NSManagedObjectContext) {
        self.callBackQueue = callBackQueue
        self.moc = moc
        super.init()
        RequestAvailableNotification.addObserver(self)
    }

    deinit {
        RequestAvailableNotification.removeObserver(self)
        tokens.forEach(NotificationCenter.default.removeObserver)
    }
    
    public func newRequestsAvailable() {
        requestAvailableClosure?()
    }
    
    public func newMsgRequestsAvailable() {}
    
    public func newExtensionStreamRequestsAvailable() {
        requestAvailableClosure?()
    }
    
    public func newExtensionSingleRequestsAvailable() {
        requestAvailableClosure?()
    }

}

public class RequestGeneratingOperationLoop {

    private let operationLoop: OperationLoop!
    private let callBackQueue: OperationQueue
    private var moc: NSManagedObjectContext
    
    private let requestGeneratorStore: RequestGeneratorStore
    private let requestGeneratorObserver: RequestGeneratorObserver
    private unowned let transportSession: ZMTransportSession
    

    init(callBackQueue: OperationQueue = .main, requestGeneratorStore: RequestGeneratorStore, transportSession: ZMTransportSession, moc: NSManagedObjectContext, type: OperationLoop.ObserverType = .newRequest) {
        self.moc = moc
        self.callBackQueue = callBackQueue
        self.requestGeneratorStore = requestGeneratorStore
        self.requestGeneratorObserver = RequestGeneratorObserver()
        self.transportSession = transportSession
        self.operationLoop = OperationLoop(callBackQueue: callBackQueue, moc: moc)

        operationLoop.requestAvailableClosure = { [weak self] in self?.enqueueRequests() }
        requestGeneratorObserver.observedGenerator = { [weak self] in self?.requestGeneratorStore.nextRequest() }
    }

    deinit {
        transportSession.tearDown()
        requestGeneratorStore.tearDown()
    }
    
    fileprivate func enqueueRequests() {
        var result : ZMTransportEnqueueResult
        
        repeat {
            result = transportSession.attemptToEnqueueSyncRequest(generator: { [weak self] in self?.requestGeneratorObserver.nextRequest() })
        } while result.didGenerateNonNullRequest && result.didHaveLessRequestThanMax
        
    }
}


