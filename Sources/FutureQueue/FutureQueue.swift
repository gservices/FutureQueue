import Foundation

public struct Future<T> {
    public enum Result<T> {
        case success(T)
        case failure(Error)
    }
    
    fileprivate var result: Result<T>?
    
    fileprivate init(result: Result<T>? = nil) {
        self.result = result
    }
    
    public var value: T? {
        guard let result = self.result, case .success(let value) = result else {
            return nil
        }
        return value
    }
    
    public var error: Error? {
        guard let result = self.result, case .failure(let error) = result else {
            return nil
        }
        return error
    }
    
    public var isPending: Bool {
        return self.result == nil
    }
    
    public var isFulfilled: Bool {
        return self.value != nil
    }
    
    public var isRejected: Bool {
        return self.error != nil
    }
}

open class FutureQueue<T> {
    fileprivate struct FurureCallback<T> {
        fileprivate let queue: DispatchQueue
        fileprivate let onSuccess: ((T) -> Void)
        fileprivate let onFailure: ((Error) -> Void)
        
        fileprivate init(
            queue: DispatchQueue,
            onSuccess: @escaping ((T) -> Void),
            onFailure: @escaping ((Error) -> Void))
        {
            self.queue = queue
            self.onSuccess = onSuccess
            self.onFailure = onFailure
        }
    }
    
    private var future: Future<T>
    private var callbacks: [FurureCallback<T>] = []
    private let lockQueue = DispatchQueue(label: "dispatch.futurequeue.lock.queue", qos: .userInitiated)
    private var executionQueue: DispatchQueue
    
    public init(_ on: DispatchQueue = .global(qos: .userInitiated), _ future: Future<T>? = nil) {
        self.executionQueue = on
        self.future = future ?? Future()
    }
    
    public convenience init(queue: DispatchQueue = .global(qos: .default), value: T) {
        self.init(queue, Future(result: .success(value)))
    }
    
    public convenience init(queue: DispatchQueue = .global(qos: .default), error: Error) {
        self.init(queue, Future(result: .failure(error)))
    }
    
    public convenience init(
        queue: DispatchQueue = .global(qos: .default),
        block: @escaping (_ fulfill: @escaping ((T) -> Void),
                          _ reject: @escaping ((Error) -> Void)) throws -> Void)
    {
        self.init(queue)
        queue.async {
            do {
                try block(self.fulfill, self.reject)
            } catch {
                self.reject(error)
            }
        }
    }
    
    public convenience init(
        queue: DispatchQueue = .global(qos: .default),
        block: @escaping () throws -> T)
    {
        self.init(queue)
        
        queue.async {
            do {
                self.fulfill(try block())
            } catch {
                self.reject(error)
            }
        }
    }
    
    @discardableResult
    fileprivate func then(
        queue: DispatchQueue? = nil,
        success: @escaping ((T) -> Void),
        failure: @escaping ((Error) -> Void)) -> FutureQueue<T> {
            
            let executionQueue = queue ?? self.executionQueue
            self.addCallbacks(queue: executionQueue, onFulfilled: success, onRejected: failure)
            return self
        }
    
    @discardableResult
    public func then<U>(
        queue: DispatchQueue? = nil,
        _ f: @escaping ((T) throws -> FutureQueue<U>)) -> FutureQueue<U> {
            
            let executionQueue = queue ?? self.executionQueue
            
            return FutureQueue<U>(queue: self.executionQueue) { fulfill, reject in
                self.addCallbacks(
                    queue: executionQueue,
                    onFulfilled: { value in
                        do {
                            try f(value).then(queue: queue, success: fulfill, failure: reject)
                        }
                        catch {
                            reject(error)
                        }
                    },
                    onRejected: reject
                )
            }
        }
    
    @discardableResult
    public func thenMap<U>(
        queue: DispatchQueue? = nil,
        _ f: @escaping ((T) throws -> U)) -> FutureQueue<U> {
            
            let executionQueue = queue ?? self.executionQueue
            
            return self.then(queue: executionQueue) { value -> FutureQueue<U> in
                do {
                    return FutureQueue<U>(queue: self.executionQueue, value: try f(value))
                } catch {
                    return FutureQueue<U>(queue: self.executionQueue, error: error)
                }
            }
        }
    
    @discardableResult
    public func onSuccess(
        queue: DispatchQueue? = nil,
        _ success: @escaping ((T) -> Void)) -> FutureQueue<T> {
            return self.then(queue: queue, success: success, failure: { _ in })
        }
    
    @discardableResult
    public func onFailure(
        queue: DispatchQueue? = nil,
        _ failure: @escaping ((Error) -> Void)) -> FutureQueue<T> {
            return self.then(queue: queue, success: { _ in }, failure: failure)
        }
    
    private func update(_ future: Future<T>) {
        guard self.isPending else {
            return
        }
        self.lockQueue.sync {
            self.future = future
        }
        self.runCallbacks()
    }
    
    public func fulfill(_ value: T) {
        self.update(Future(result: .success(value)))
    }
    
    public func reject(_ error: Error) {
        self.update(Future(result: .failure(error)))
    }
    
    public var isPending: Bool {
        return !self.isFulfilled && !self.isRejected
    }
    
    public var isFulfilled: Bool {
        return self.value != nil
    }
    
    public var isRejected: Bool {
        return self.error != nil
    }
    
    public var value: T? {
        return self.lockQueue.sync {
            return self.future.value
        }
    }
    
    public var error: Error? {
        return self.lockQueue.sync {
            return self.future.error
        }
    }
    
    private func addCallbacks(
        queue: DispatchQueue,
        onFulfilled: @escaping ((T) -> Void),
        onRejected: @escaping ((Error) -> Void)) {
            
            let callback = FurureCallback(queue: queue, onSuccess: onFulfilled, onFailure: onRejected)
            self.lockQueue.async {
                self.callbacks.append(callback)
            }
            
            self.runCallbacks()
        }
    
    private func runCallbacks() {
        self.lockQueue.async(execute: {
            guard let callback = self.callbacks.first, !self.future.isPending else {
                return
            }
            self.callbacks.removeFirst()
            
            let group = DispatchGroup()
            
            group.notify(queue: callback.queue) {
                self.runCallbacks()
            }
            
            switch self.future.result! {
            case .success(let value):
                callback.queue.async(group: group) {
                    callback.onSuccess(value)
                }
                
            case .failure(let error):
                callback.queue.async(group: group) {
                    callback.onFailure(error)
                }
            }
        })
    }
}

public enum FutureQueues {
    
    public enum Errors: Error {
        case validation
        case timeout
    }
    
    public static func first<T>(queue: DispatchQueue? = nil,
                                _ block: @escaping () throws -> FutureQueue<T>) -> FutureQueue<T> {
        return FutureQueue(value: ()).then(queue: queue, block)
    }
    
    public static func first<T>(queue: DispatchQueue? = nil,
                                _ block: @escaping () throws -> T) -> FutureQueue<T> {
        return FutureQueue(value: ()).thenMap(queue: queue, block)
    }
    
    @discardableResult
    public static func delay(_ delay: DispatchTimeInterval) -> FutureQueue<()> {
        return FutureQueue<()> { fulfill, _ in
            let time = DispatchTime.now() + delay
            DispatchQueue.main.asyncAfter(deadline: time) {
                fulfill(())
            }
        }
    }
    
    @discardableResult
    public static func timeout<T>(_ timeout: DispatchTimeInterval) -> FutureQueue<T> {
        return FutureQueue<T> { _, reject in
            FutureQueues.delay(timeout)
                .onSuccess {
                    reject(FutureQueues.Errors.timeout)
                }
        }
    }
    
    @discardableResult
    public static func all<T>(_ futures: [FutureQueue<T>]) -> FutureQueue<[T]> {
        return FutureQueue<[T]> { fulfill, reject in
            guard !futures.isEmpty else {
                return fulfill([])
            }
            
            for future in futures {
                future.then(success: { value in
                    if !futures.contains(where: { $0.isRejected || $0.isPending }) {
                        fulfill(futures.compactMap { $0.value })
                    }
                }, failure: reject)
            }
        }
    }
    
    @discardableResult
    public static func wait<T>(_ futures: [FutureQueue<T>]) -> FutureQueue<Void> {
        return FutureQueue<Void> { fulfill, _ in
            guard !futures.isEmpty else {
                return fulfill(())
            }
            let complete: ((Any) -> Void) = { _ in
                if !futures.contains(where: { $0.isPending }) {
                    fulfill(())
                }
            }
            for future in futures {
                future.then(success: complete, failure: complete)
            }
        }
    }
    
    @discardableResult
    public static func race<T>(_ futures: [FutureQueue<T>]) -> FutureQueue<T> {
        return FutureQueue<T> { fulfill, reject in
            guard !futures.isEmpty else {
                fatalError("Could not race empty promises array.")
            }
            
            for future in futures {
                future.then(success: fulfill, failure: reject)
            }
        }
    }
    
    @discardableResult
    public static func zip<T1, T2>(_ p1: FutureQueue<T1>,
                                   _ last: FutureQueue<T2>) -> FutureQueue<(T1, T2)> {
        return FutureQueue<(T1, T2)> { fulfill, reject in
            let resolver: (Any) -> Void = { _ in
                if let firstValue = p1.value, let secondValue = last.value {
                    fulfill((firstValue, secondValue))
                }
            }
            p1.then(success: resolver, failure: reject)
            last.then(success: resolver, failure: reject)
        }
    }
    
    @discardableResult
    public static func zip<T1, T2, T3>(_ p1: FutureQueue<T1>,
                                       _ p2: FutureQueue<T2>,
                                       _ last: FutureQueue<T3>) -> FutureQueue<(T1, T2, T3)> {
        return FutureQueue<(T1, T2, T3)> { (fulfill: @escaping ((T1, T2, T3)) -> Void, reject: @escaping (Error) -> Void) in
            let zipped: FutureQueue<(T1, T2)> = zip(p1, p2)
            
            let resolver: (Any) -> Void = { _ in
                if let zippedValue = zipped.value, let lastValue = last.value {
                    fulfill((zippedValue.0, zippedValue.1, lastValue))
                }
            }
            zipped.then(success: resolver, failure: reject)
            last.then(success: resolver, failure: reject)
        }
    }
    
    @discardableResult
    public static func zip<T1, T2, T3, T4>(_ p1: FutureQueue<T1>,
                                           _ p2: FutureQueue<T2>,
                                           _ p3: FutureQueue<T3>,
                                           _ last: FutureQueue<T4>) -> FutureQueue<(T1, T2, T3, T4)> {
        return FutureQueue<(T1, T2, T3, T4)> { (fulfill: @escaping ((T1, T2, T3, T4)) -> Void, reject: @escaping (Error) -> Void) in
            
            let zipped: FutureQueue<(T1, T2, T3)> = zip(p1, p2, p3)
            let resolver: (Any) -> Void = { _ in
                if let zippedValue = zipped.value, let lastValue = last.value {
                    fulfill((zippedValue.0, zippedValue.1, zippedValue.2, lastValue))
                }
            }
            
            zipped.then(success: resolver, failure: reject)
            last.then(success: resolver, failure: reject)
        }
    }
    
    @discardableResult
    public static func retry<T>(times: Int,
                                delay: DispatchTimeInterval,
                                generate: @escaping () -> FutureQueue<T>) -> FutureQueue<T> {
        if times <= 0 {
            return generate()
        }
        
        return FutureQueue<T> { fulfill, reject in
            generate().recover { _ in
                return FutureQueues.delay(delay).then { _ in
                    return self.retry(times: times - 1, delay: delay, generate: generate)
                }
            }
            .then(success: fulfill, failure: reject)
        }
    }
}

public extension FutureQueue {
    @discardableResult
    func tap(queue: DispatchQueue? = nil, _ block: @escaping (() -> Void)) -> FutureQueue<T> {
        return self.thenMap(queue: queue) { value -> T in
            block()
            return value
        }
    }
    
    @discardableResult
    func tap(queue: DispatchQueue? = nil, _ block: @escaping ((T) -> Void)) -> FutureQueue<T> {
        return self.thenMap(queue: queue) { value -> T in
            block(value)
            return value
        }
    }
    
    @discardableResult
    func validate(_ condition: @escaping (T) -> Bool) -> FutureQueue<T> {
        return self.thenMap { value -> T in
            guard condition(value) else {
                throw FutureQueues.Errors.validation
            }
            return value
        }
    }
    
    @discardableResult
    func always(queue: DispatchQueue? = nil, _ block: @escaping () -> Void) -> FutureQueue<T> {
        return self.then(queue: queue, success: { _ in block() }, failure: { _ in block() })
    }
    
    @discardableResult
    func timeout(_ timeout: DispatchTimeInterval) -> FutureQueue<T> {
        return FutureQueues.race([self, FutureQueues.timeout(timeout)])
    }
    
    @discardableResult
    func recover(recovery: @escaping (Error) throws -> FutureQueue<T>) -> FutureQueue<T> {
        return FutureQueue<T> { fulfill, reject in
            self.then(success: fulfill, failure: { error in
                do {
                    try recovery(error).then(success: fulfill, failure: reject)
                } catch {
                    reject(error)
                }
            })
        }
    }
}
