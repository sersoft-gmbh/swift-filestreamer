import Foundation
import SystemPackage

/// A file stream that continously reads the generic `Value` type from a given file.
public struct FileStream<Value> {
    private typealias FileSource = DispatchSourceRead
    /// The callback that is called whenever values are read from the file.
    public typealias Callback = (Array<Value>) -> ()

    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public struct Sequence: AsyncSequence {
        public typealias Element = AsyncIterator.Element

        @frozen
        public struct AsyncIterator: AsyncIteratorProtocol {
            public typealias Element = Value

            @usableFromInline
            var _iterator: AsyncStream<Element>.AsyncIterator

            @usableFromInline
            init(_iterator: AsyncStream<Element>.AsyncIterator) {
                self._iterator = _iterator
            }

            @inlinable
            public mutating func next() async -> Element? {
                await _iterator.next()
            }
        }

        @usableFromInline
        let _stream: AsyncStream<Element>

        // FIXME: This doesn't work as expected yet.
//        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
//        @available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
//        private static func _modernDarwinImpl(for fileDescriptor: FileDescriptor, using cont: AsyncStream<Value>.Continuation) {
//            Task<Void, Never> {
//                guard !Task.isCancelled else { return cont.finish() }
//                let bytes = FileHandle(fileDescriptor: fileDescriptor.rawValue, closeOnDealloc: false).bytes
//                let rawSize = MemoryLayout<Value>.size
//                var buffer = ContiguousArray<UInt8>()
//                buffer.reserveCapacity(rawSize)
//                do {
//                    for try await byte in bytes {
//                        buffer.append(byte)
//                        if buffer.count == rawSize {
//                            if case .terminated = buffer.withUnsafeBytes({
//                                cont.yield($0.load(as: Value.self))
//                            }) {
//                                break
//                            }
//                            buffer.removeAll(keepingCapacity: true)
//                        }
//                    }
//                } catch {
//                    print("Reading failed: \(error)")
//                    cont.finish()
//                }
//            }
//        }
//        #endif
        private static func _legacyGCDImpl(for fileDescriptor: FileDescriptor, using cont: AsyncStream<Value>.Continuation) {
            let source = _inactiveSource(from: fileDescriptor) {
                for elem in $0 {
                    if case .terminated = cont.yield(elem) {
                        break
                    }
                }
            }
#if swift(>=5.6)
            cont.onTermination = { _ in _terminateSource(source) }
#else
            @Sendable
            func handleTermination(with reason: AsyncStream<Element>.Continuation.Termination) { _terminateSource(source) }
            cont.onTermination = .some(handleTermination)
#endif
            _activatedSource(source)
        }

        public init(fileDescriptor: FileDescriptor) {
            _stream = .init(Element.self, {
//                #if os(Linux)
                Self._legacyGCDImpl(for: fileDescriptor, using: $0)
//                #else
//                if #available(macOS 12, iOS 15, tvOS 15, watchOS 8, *) {
//                    Self._modernDarwinImpl(for: fileDescriptor, using: $0)
//                } else {
//                    Self._legacyGCDImpl(for: fileDescriptor, using: $0)
//                }
//                #endif
            })
        }

        @inlinable
        public func makeAsyncIterator() -> AsyncIterator {
            .init(_iterator: _stream.makeAsyncIterator())
        }
    }

    private enum State {
        case idle
        case streaming(FileSource)
    }

    private final class Storage {
        struct Values {
            var state: State = .idle
        }

        private let lock = DispatchQueue(label: "de.sersoft.filestreamer.filestream.storage.lock")
        private var values = Values()

        init() {}

        deinit {
            if case .streaming(let source) = values.state {
                print("Warning: FileStream storage was deallocated without stopping streaming!")
                source.cancel()
            }
        }

        func withValues<T>(do work: (inout Values) throws -> T) rethrows -> T {
            dispatchPrecondition(condition: .notOnQueue(lock))
            return try lock.sync { try work(&values) }
        }

        func with<Value, T>(_ keyPath: WritableKeyPath<Values, Value>, do work: (inout Value) throws -> T) rethrows -> T {
            try withValues { try work(&$0[keyPath: keyPath]) }
        }
    }

    /// The file descriptor of this stream.
    /// - Note: The file descriptor is not managed by this type. Opening and closing the file descriptor is the responsibility of the caller.
    public let fileDescriptor: FileDescriptor

    private let callback: Callback

    private let storage = Storage()

    /// Creates a new stream using the given file descriptor.
    /// The descriptor should be open for reading!
    /// - Parameter fileDescriptor: The file descriptor to use.
    /// - Parameter callback: The callback to call when values are read.
    /// - Note: The file descriptor is not managed by this type. Opening and closing the file descriptor is the responsibility of the caller.
    public init(fileDescriptor: FileDescriptor, callback: @escaping Callback) {
        self.fileDescriptor = fileDescriptor
        self.callback = callback
    }

    /// Starts streaming values from the given file descriptor.
    public func beginStreaming() {
        storage.with(\.state) {
            guard case .idle = $0 else { return }
            $0 = .streaming(_beginStreaming(from: fileDescriptor))
        }
    }

    private func _beginStreaming(from fileDesc: FileDescriptor) -> FileSource {
        Self._activatedSource(Self._inactiveSource(from: fileDesc, informing: callback))
    }

    /// Ends streaming. Does not close the file descriptor.
    public func endStreaming() {
        storage.with(\.state) {
            guard case .streaming(let source) = $0 else { return }
            Self._terminateSource(source)
            $0 = .idle
        }
    }
}

extension FileStream {
    private static func _inactiveSource(from fileDesc: FileDescriptor, informing callback: @escaping Callback) -> FileSource {
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
                    callback(Array(buffer.prefix(noOfValues)))
                }
                let leftOverBytes = bytesRead % rawSize
                remainingData -= .init(bytesRead - leftOverBytes)
                if leftOverBytes > 0 {
                    do {
                        try fileDesc.seek(offset: .init(-leftOverBytes), from: .current)
                    } catch {
                        // If we failed to seek, we need to drop the left-over bytes.
                        remainingData -= .init(leftOverBytes)
                        print("Too much data was read from the file handle, but seeking back failed: \(error)")
                    }
                }
            } catch {
                print("Failed to read from event file: \(error)")
            }
        }
        return source
    }

    @discardableResult
    private static func _activatedSource(_ source: FileSource) -> FileSource {
        source.activate()
        return source
    }

    private static func _terminateSource(_ source: FileSource) {
        source.cancel()
    }
}
