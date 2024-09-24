#if swift(>=6.0) // Currently fails to build otherwise
fileprivate import Foundation
#endif
fileprivate import Dispatch
public import SystemPackage

/// An async sequence that continously streams the generic `Value` type from a given file.
public struct FileStream<Value>: AsyncSequence {
    public typealias Element = AsyncIterator.Element
    public typealias Failure = AsyncIterator.Failure

    /// Defines how failures should be handled.
    public struct FailureBehavior: Sendable {
#if swift(>=6.0)
        private let handler: @Sendable (any Error) throws(Failure) -> ()
#else
        private let handler: @Sendable (any Error) throws -> ()
#endif

#if swift(>=6.0)
        internal func handleError(_ error: any Error) throws(Failure) {
            try handler(error)
        }
#else
        internal func handleError(_ error: any Error) throws {
            try handler(error)
        }
#endif

#if swift(>=6.0)
        /// The error is handled by the given closure. Throwing from the closure will terminate the sequence.
        public static func custom(_ handler: @escaping @Sendable (any Error) throws(Failure) -> ()) -> Self {
            .init(handler: handler)
        }
#else
        /// The error is handled by the given closure. Throwing from the closure will terminate the sequence.
        public static func custom(_ handler: @escaping @Sendable (any Error) throws -> ()) -> Self {
            .init(handler: handler)
        }
#endif

        /// Any error is thrown from the sequence (terminating it).
        public static var `throw`: Self { .init { throw $0 } }

        /// Errors are simply printed. The sequence will continue afterwards.
        public static var print: Self {
            .init { Swift.print("\(FileStream.self): An error occurred: \($0)") }
        }
    }

    @usableFromInline
    typealias Stream = AsyncThrowingStream<Element, Failure>

    @frozen
    public struct AsyncIterator: AsyncIteratorProtocol {
        public typealias Element = Value
        public typealias Failure = any Error

        @usableFromInline
        var _iterator: Stream.AsyncIterator

        @usableFromInline
        init(_iterator: Stream.AsyncIterator) {
            self._iterator = _iterator
        }

        @inlinable
        public mutating func next() async throws -> Element? {
            try await _iterator.next()
        }

#if swift(>=6.0)
        @inlinable
        @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
        public mutating func next(isolation actor: isolated (any Actor)?) async throws(Failure) -> Value? {
            try await _iterator.next(isolation: `actor`)
        }
#endif
    }

    @usableFromInline
    let _stream: Stream

    public init(fileDescriptor: FileDescriptor, failureBehavior: FailureBehavior = .`throw`) {
        _stream = .init(Element.self, {
            Self._gcdImplementation(for: fileDescriptor, using: $0, handlingFailuresWith: failureBehavior)
        })
    }

    @inlinable
    public func makeAsyncIterator() -> AsyncIterator {
        .init(_iterator: _stream.makeAsyncIterator())
    }
}

extension FileStream: Sendable where Value: Sendable {}

extension FileStream {
    private static func _gcdImplementation(for fileDescriptor: FileDescriptor,
                                           using cont: Stream.Continuation,
                                           handlingFailuresWith failureBehavior: FailureBehavior) {
        let source = _inactiveSource(from: fileDescriptor) {
            cont.yield($0)
        } onFailure: {
            do {
                try failureBehavior.handleError($0)
            } catch {
                cont.finish(throwing: error)
            }
        }
        cont.onTermination = { _ in source.cancel() }
        source.activate()
    }
}

fileprivate struct SendableDispatchSource: @unchecked Sendable {
    let source: any DispatchSourceRead

    func activate() {
        source.activate()
    }

    func cancel() {
        source.cancel()
    }
}

extension FileStream {
#if swift(>=6.0)
    private typealias _ElementCallback = (sending Element) -> ()
#else
    private typealias _ElementCallback = (Element) -> ()
#endif

    private static func _inactiveSource(from fileDesc: FileDescriptor,
                                        onElement elementCallback: @escaping _ElementCallback,
                                        onFailure failureCallback: @escaping (any Error) -> ()) -> SendableDispatchSource {
#if swift(>=6.0)
        let unsafeCallback = unsafeBitCast(elementCallback, to: ((Element) -> ()).self)
#endif
        func send(_ value: Element) {
#if swift(>=6.0)
            unsafeCallback(value)
#else
            elementCallback(value)
#endif
        }

        let workerQueue = DispatchQueue(label: "de.sersoft.filestreamer.filestream.gcd.worker")
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDesc.rawValue, queue: workerQueue)
        let rawSize = MemoryLayout<Value>.size
        let rawSize64 = UInt64(rawSize)
        var remainingData: UInt64 = 0
        source.setEventHandler {
            do {
                remainingData += .init(source.data)
                guard case let capacity = remainingData / rawSize64, capacity > 0 else { return }
                let buffer = UnsafeMutableBufferPointer<Element>.allocate(capacity: .init(capacity))
                defer { buffer.deallocate() }
                let bytesRead = try fileDesc.read(into: UnsafeMutableRawBufferPointer(buffer))
                if case let noOfValues = bytesRead / rawSize, noOfValues > 0 {
                    for value in buffer.prefix(noOfValues) {
                        send(value)
                    }
                }
                let leftOverBytes = bytesRead % rawSize
                remainingData -= .init(bytesRead - leftOverBytes)
                if leftOverBytes > 0 {
                    do {
                        try fileDesc.seek(offset: .init(-leftOverBytes), from: .current)
                    } catch {
                        // If we failed to seek, we need to drop the left-over bytes.
                        remainingData -= .init(leftOverBytes)
                        throw error // Re-throw to land it in the failureCallback below
                    }
                }
            } catch {
                failureCallback(error)
            }
        }
        return .init(source: source)
    }
}
