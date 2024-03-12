import Dispatch
import SystemPackage

/// An async sequence that continously streams the generic `Value` type from a given file.
public struct FileStream<Value>: AsyncSequence {
    public typealias Element = AsyncIterator.Element
    
    /// Defines how failures should be handled.
    public struct FailureBehavior: Sendable {
        private let handler: @Sendable (any Error) throws -> ()

        func handleError(_ error: some Error) throws {
            try handler(error)
        }

        /// The error is handled by the given closure. Throwing from the closure will terminate the sequence.
        public static func custom(_ handler: @escaping @Sendable (any Error) throws -> ()) -> Self {
            .init(handler: handler)
        }

        /// Any error is thrown from the sequence (terminating it).
        public static var `throw`: Self { .init { throw $0 } }

        /// Errors are simply printed. The sequence will continue afterwards.
        public static var print: Self {
            .init { Swift.print("\(FileStream.self): An error occurred: \($0)") }
        }
    }

    @usableFromInline
    typealias Stream = AsyncThrowingStream<Element, any Error>

    @frozen
    public struct AsyncIterator: AsyncIteratorProtocol {
        public typealias Element = Value

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

extension FileStream {
    private static func _gcdImplementation(for fileDescriptor: FileDescriptor,
                                           using cont: Stream.Continuation,
                                           handlingFailuresWith failureBehavior: FailureBehavior) {
        let source = _inactiveSource(from: fileDescriptor) {
            switch $0 {
            case .success(let values):
                for elem in values {
                    if case .terminated = cont.yield(elem) {
                        break
                    }
                }
            case .failure(let error):
                do {
                    try failureBehavior.handleError(error)
                } catch {
                    cont.finish(throwing: error)
                }
            }
        }
        cont.onTermination = { _ in _terminateSource(source) }
        source.activate()
    }
}

extension FileStream {
    private static func _inactiveSource(from fileDesc: FileDescriptor,
                                        informing callback: @escaping (Result<Array<Element>, any Error>) -> ()) -> any DispatchSourceRead {
        let workerQueue = DispatchQueue(label: "de.sersoft.filestreamer.filestream.worker")
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDesc.rawValue, queue: workerQueue)
        let rawSize = MemoryLayout<Value>.size
        let rawSize64 = UInt64(rawSize)
        var remainingData: UInt64 = 0
        source.setEventHandler {
            do {
                remainingData += .init(source.data)
                guard case let capacity = remainingData / rawSize64, capacity > 0 else { return }
                let buffer = UnsafeMutableBufferPointer<Value>.allocate(capacity: .init(capacity))
                defer { buffer.deallocate() }
                let bytesRead = try fileDesc.read(into: UnsafeMutableRawBufferPointer(buffer))
                if case let noOfValues = bytesRead / rawSize, noOfValues > 0 {
                    callback(.success(Array(buffer.prefix(noOfValues))))
                }
                let leftOverBytes = bytesRead % rawSize
                remainingData -= .init(bytesRead - leftOverBytes)
                if leftOverBytes > 0 {
                    do {
                        try fileDesc.seek(offset: .init(-leftOverBytes), from: .current)
                    } catch {
                        // If we failed to seek, we need to drop the left-over bytes.
                        remainingData -= .init(leftOverBytes)
                        callback(.failure(error))
                    }
                }
            } catch {
                callback(.failure(error))
            }
        }
        return source
    }

    private static func _terminateSource(_ source: some DispatchSourceRead) {
        source.cancel()
    }
}
