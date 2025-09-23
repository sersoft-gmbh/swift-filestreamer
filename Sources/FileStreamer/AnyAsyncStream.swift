@frozen
@usableFromInline
struct AnyAsyncStream<Element, Failure: Error>: AsyncSequence {
    @frozen
    @usableFromInline
    enum Storage {
        case nonThrowing(AsyncStream<Element>)
        case throwing(AsyncThrowingStream<Element, Failure>)
    }

    @frozen
    @usableFromInline
    enum AsyncIterator: AsyncIteratorProtocol {
        case nonThrowing(AsyncStream<Element>.Iterator)
        case throwing(AsyncThrowingStream<Element, Failure>.Iterator)

        @inlinable
        mutating func next() async throws -> Element? {
            switch self {
            case .nonThrowing(var iterator):
                defer { self = .nonThrowing(iterator) }
                return await iterator.next()
            case .throwing(var iterator):
                defer { self = .throwing(iterator) }
                return try await iterator.next()
            }
        }

        @inlinable
        mutating func next(isolation actor: isolated (any Actor)?) async throws(Failure) -> Element? {
            switch self {
            case .nonThrowing(var iterator):
                defer { self = .nonThrowing(iterator) }
                return await iterator.next(isolation: actor)
            case .throwing(var iterator):
                defer { self = .throwing(iterator) }
                return try await iterator.next(isolation: actor)
            }
        }
    }

    @usableFromInline
    let _storage: Storage

    @inlinable
    init(_storage: Storage) {
        self._storage = _storage
    }

    @inlinable
    public func makeAsyncIterator() -> AsyncIterator {
        switch _storage {
        case .nonThrowing(let stream): .nonThrowing(stream.makeAsyncIterator())
        case .throwing(let stream): .throwing(stream.makeAsyncIterator())
        }
    }
}

extension AnyAsyncStream.Storage: Sendable where Element: Sendable {}
extension AnyAsyncStream: Sendable where Element: Sendable {}

extension AnyAsyncStream where Failure == any Error {
    @inlinable
    static func throwing(_ stream: AsyncThrowingStream<Element, Failure>) -> Self {
        .init(_storage: .throwing(stream))
    }
}

extension AnyAsyncStream where Failure == Never {
    @inlinable
    static func nonThrowing(_ stream: AsyncStream<Element>) -> Self {
        .init(_storage: .nonThrowing(stream))
    }
}

#if compiler(>=6.1)
typealias AsyncStreamTerminationReasonBase = Sendable
#else
typealias AsyncStreamTerminationReasonBase = Any
#endif
protocol AsyncStreamTerminationReason<Failure>: AsyncStreamTerminationReasonBase {
    associatedtype Failure: Error

    static var cancelled: Self { get }
    static func finished(_ failure: Failure?) -> Self
}
extension AsyncStream.Continuation.Termination: AsyncStreamTerminationReason {
    typealias Failure = Never

    static func finished(_ failure: Failure?) -> Self { .finished }
}
extension AsyncThrowingStream.Continuation.Termination: AsyncStreamTerminationReason {}

protocol AsyncStreamYieldResult {}

extension AsyncStream.Continuation.YieldResult: AsyncStreamYieldResult {}
extension AsyncThrowingStream.Continuation.YieldResult: AsyncStreamYieldResult {}

protocol AsyncStreamContinuation<Element, Failure>: Sendable {
    associatedtype Element
    associatedtype Failure: Error
    associatedtype TerminationReason: AsyncStreamTerminationReason
    associatedtype YieldResult: AsyncStreamYieldResult

    var onTermination: (@Sendable (TerminationReason) -> Void)? { get nonmutating set }

    @discardableResult
    func yield(_ value: sending Element) -> YieldResult
    func finish(throwing error: Failure?)
}
extension AsyncStream.Continuation: AsyncStreamContinuation {
    typealias Failure = Never

    func finish(throwing error: Failure?) { finish() }
}
extension AsyncThrowingStream.Continuation: AsyncStreamContinuation {}
