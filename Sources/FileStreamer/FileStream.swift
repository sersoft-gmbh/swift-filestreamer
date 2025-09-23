fileprivate import Foundation
fileprivate import Dispatch
public import SystemPackage

/// An async sequence that continously streams the generic `Element` type from a given file.
/// The `Failure` type describes the errors thrown for the sequence. The ``FailureBehavior`` is used to handle errors.
public struct FileStream<Element, Failure: Error>: AsyncSequence {
    /// Defines how failures should be handled.
    public struct FailureBehavior: Sendable {
        private let handler: @Sendable (any Error) throws(Failure) -> ()

        internal func handleError(_ error: any Error) throws(Failure) {
            try handler(error)
        }

        /// The error is handled by the given closure. Throwing from the closure will terminate the sequence.
        public static func custom(_ handler: @escaping @Sendable (any Error) throws(Failure) -> ()) -> Self {
            .init(handler: handler)
        }
    }

    @usableFromInline
    let _stream: AnyAsyncStream<Element, Failure>

    /// Creates a new file stream for the given `fileDescriptor`.
    /// The `failureBehavior` defines how errors are handled.
    /// - Parameters:
    ///   - fileDescriptor: The file descriptor to stream from.
    ///   - failureBehavior: How to handle failures of the underlying stream.
    public init(fileDescriptor: FileDescriptor, failureBehavior: FailureBehavior)
    where Failure == Never
    {
        _stream = .nonThrowing(.init(Element.self, {
            Self._gcdImplementation(for: fileDescriptor, using: $0, handlingFailuresWith: failureBehavior)
        }))
    }

    /// Creates a new file stream for the given `fileDescriptor`.
    /// The `failureBehavior` defines how errors are handled.
    /// - Parameters:
    ///   - fileDescriptor: The file descriptor to stream from.
    ///   - failureBehavior: How to handle failures of the underlying stream.
    public init(fileDescriptor: FileDescriptor, failureBehavior: FailureBehavior)
    where Failure == any Error // This is currently a limitation of AsyncThrowingStream
    {
        _stream = .throwing(.init(Element.self, {
            Self._gcdImplementation(for: fileDescriptor, using: $0, handlingFailuresWith: failureBehavior)
        }))
    }

    @inlinable
    public func makeAsyncIterator() -> some AsyncIteratorProtocol<Element, Failure> {
        _stream.makeAsyncIterator()
    }
}

extension FileStream.FailureBehavior where Failure == any Error {
    /// Any error is thrown from the sequence (terminating it).
    public static var `throw`: Self { .init { throw $0 } }
}

extension FileStream.FailureBehavior where Failure == Never {
    /// Errors are simply printed. The sequence will continue afterwards.
    public static var print: Self {
        .init { Swift.print("\(FileStream.self): An error occurred: \($0)") }
    }
}

extension FileStream: Sendable where Element: Sendable {}

extension FileStream {
    private static func _gcdImplementation(for fileDescriptor: FileDescriptor,
                                           using cont: some AsyncStreamContinuation<Element, Failure>,
                                           handlingFailuresWith failureBehavior: FailureBehavior) {
        let source = _inactiveSource(from: fileDescriptor) {
            cont.yield($0)
        } onFailure: {
            do throws(Failure) {
                try failureBehavior.handleError($0)
            } catch {
                cont.finish(throwing: error)
            }
        }
        cont.onTermination = { _ in source.cancel() }
        source.activate()
    }
}

#if swift(>=6.2) && canImport(Darwin)
fileprivate typealias SendableDispatchSource = any DispatchSourceRead
#else
fileprivate struct SendableDispatchSource: @unchecked Sendable {
    let source: any DispatchSourceRead

    func activate() {
        source.activate()
    }

    func cancel() {
        source.cancel()
    }
}
#endif

extension FileStream {
    private static func _inactiveSource(from fileDesc: FileDescriptor,
                                        onElement elementCallback: @escaping @Sendable (sending Element) -> (),
                                        onFailure failureCallback: @escaping @Sendable (any Error) -> ()) -> SendableDispatchSource {
#if compiler(>=6.2)
        let unsafeCallback = unsafe unsafeBitCast(elementCallback, to: (@Sendable (Element) -> ()).self)
#else
        let unsafeCallback = unsafeBitCast(elementCallback, to: (@Sendable (Element) -> ()).self)
#endif
        @Sendable
        func send(_ value: Element) {
            unsafeCallback(value)
        }

        let workerQueue = DispatchQueue(label: "de.sersoft.filestreamer.filestream.gcd.worker")
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDesc.rawValue, queue: workerQueue)
        let rawSize = MemoryLayout<Element>.size
        let rawSize64 = UInt64(rawSize)
        var remainingData: UInt64 = 0
        source.setEventHandler {
            do {
                remainingData += .init(source.data)
                guard case let capacity = remainingData / rawSize64, capacity > 0 else { return }
                let buffer = UnsafeMutableBufferPointer<Element>.allocate(capacity: .init(capacity))
#if compiler(>=6.2)
                defer { unsafe buffer.deallocate() }
                let bytesRead = unsafe try fileDesc.read(into: UnsafeMutableRawBufferPointer(buffer))
#else
                defer { buffer.deallocate() }
                let bytesRead = try fileDesc.read(into: UnsafeMutableRawBufferPointer(buffer))
#endif
                if case let noOfValues = bytesRead / rawSize, noOfValues > 0 {
#if compiler(>=6.2)
                    for unsafe value in unsafe buffer.prefix(noOfValues) {
                        send(value)
                    }
#else
                    for value in buffer.prefix(noOfValues) {
                        send(value)
                    }
#endif
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
#if swift(<6.2)
        return .init(source: source)
#else
        return source
#endif
    }
}
