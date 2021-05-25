import Dispatch
import SystemPackage

public struct FileStream<Value> {
    private typealias FileSource = DispatchSourceRead
    public typealias Callback = (FileStream, Array<Value>) -> ()

    private enum State {
        case idle
        case streaming(FileSource)
    }

    @dynamicMemberLookup
    private final class Storage {
        struct Values {
            var state: State = .idle
            var callbacks = Array<Callback>()
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

        subscript<Value>(dynamicMember keyPath: KeyPath<Values, Value>) -> Value {
            withValues { $0[keyPath: keyPath] }
        }
    }

    public let fileDescriptor: FileDescriptor

    private let storage = Storage()

    public init(fileDescriptor: FileDescriptor) {
        self.fileDescriptor = fileDescriptor
    }

    public func addCallback(_ callback: @escaping Callback) {
        storage.with(\.callbacks) { $0.append(callback) }
    }

    public func beginStreaming() throws {
        try storage.with(\.state) {
            guard case .idle = $0 else { return }
            $0 = try .streaming(_beginStreaming(from: fileDescriptor))
        }
    }

    private func _beginStreaming(from fileDesc: FileDescriptor) throws -> FileSource {
        let workerQueue = DispatchQueue(label: "de.sersoft.filestreamer.filestream.worker")
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDesc.rawValue, queue: workerQueue)
        let rawSize = MemoryLayout<Value>.size
        var remainingData = 0
        source.setEventHandler { [unowned storage] in
            do {
                remainingData += Int(source.data)
                guard case let capacity = remainingData / rawSize, capacity > 0 else { return }
                let buffer = UnsafeMutableBufferPointer<Value>.allocate(capacity: capacity)
                defer { buffer.deallocate() }
                let bytesRead = try fileDesc.read(into: UnsafeMutableRawBufferPointer(buffer))
                if case let noOfValues = bytesRead / rawSize, noOfValues > 0 {
                    let values = Array(buffer.prefix(noOfValues))
                    storage.callbacks.forEach { $0(self, values) }
                }
                let leftOverBytes = bytesRead % rawSize
                remainingData -= bytesRead - leftOverBytes
                if leftOverBytes > 0 {
                    do {
                        try fileDesc.seek(offset: Int64(-leftOverBytes), from: .current)
                    } catch {
                        // If we failed to seek, we need to drop the left-over bytes.
                        remainingData -= leftOverBytes
                        print("Too much data was read from the file handle, but seeking back failed: \(error)")
                    }
                }
            } catch {
                print("Failed to read from event file: \(error)")
            }
        }
        source.activate()
        return source
    }

    public func endStreaming() throws {
        try storage.with(\.state) {
            guard case .streaming(let source) = $0 else { return }
            try _endStreaming(of: source)
            $0 = .idle
        }
    }

    private func _endStreaming(of source: FileSource) throws {
        source.cancel()
    }
}
