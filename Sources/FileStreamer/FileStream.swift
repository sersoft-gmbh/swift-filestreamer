import Dispatch
import SystemPackage

public final class FileStream<Value> {
    private typealias FileSource = DispatchSourceRead

    public typealias StateCallback<StateValue> = (FileStream, StateValue) throws -> ()
    public typealias Callback = (FileStream, Array<Value>) -> ()

    private enum State {
        case closed
        case open(FileDescriptor)
        case streaming(FileDescriptor, FileSource)
    }

    private struct Storage {
        struct Callbacks {
            var open: Array<StateCallback<FileDescriptor>> = []
            var close: Array<StateCallback<FileDescriptor>> = []
            var read: Array<Callback> = []
        }

        var state: State = .closed
        var callbacks = Callbacks()
    }

    public let filePath: FilePath

    private let storageLock = DispatchQueue(label: "de.sersoft.filestreamer.storage.lock")
    private var storage = Storage()

    public init(filePath: FilePath) {
        self.filePath = filePath
    }

    deinit {
        do {
            try close()
        } catch {
            print("Trying to close the file descriptor at \(filePath) on streamer deallocation failed: \(error)")
        }
    }

    private func withStorage<T>(do work: (inout Storage) throws -> T) rethrows -> T {
        dispatchPrecondition(condition: .notOnQueue(storageLock))
        return try storageLock.sync { try work(&storage) }
    }

    private func withStorageValue<Value, T>(_ keyPath: WritableKeyPath<Storage, Value>, do work: (inout Value) throws -> T) rethrows -> T {
        try withStorage { try work(&$0[keyPath: keyPath]) }
    }

    private func getStorageValue<Value>(for keyPath: KeyPath<Storage, Value>) -> Value {
        withStorage { $0[keyPath: keyPath] }
    }

    public func addOpenCallback(_ callback: @escaping StateCallback<FileDescriptor>) {
        withStorageValue(\.callbacks.open) { $0.append(callback) }
    }

    public func addCloseCallback(_ callback: @escaping StateCallback<FileDescriptor>) {
        withStorageValue(\.callbacks.close) { $0.append(callback) }
    }

    public func addCallback(_ callback: @escaping Callback) {
        withStorageValue(\.callbacks.read) { $0.append(callback) }
    }

    public func open() throws {
        try withStorage {
            guard case .closed = $0.state else { return }
            $0.state = try .open(_open(informing: $0.callbacks.open))
        }
    }

    private func _open(informing callbacks: Array<StateCallback<FileDescriptor>>) throws -> FileDescriptor {
        let descriptor = try FileDescriptor.open(filePath, .readOnly)
        do {
            try callbacks.forEach { try $0(self, descriptor) }
        } catch {
            do {
                try descriptor.close()
            } catch {
                print("State callback for opening file at \(filePath) threw an error and trying to close the file descriptor failed: \(error)")
            }
            throw error
        }
        return descriptor
    }

    public func beginStreaming() throws {
        try withStorage {
            switch $0.state {
            case .closed:
                let fileDesc = try _open(informing: $0.callbacks.open)
                $0.state = try .streaming(fileDesc, _beginStreaming(from: fileDesc))
            case .open(let fileDesc):
                $0.state = try .streaming(fileDesc, _beginStreaming(from: fileDesc))
            case .streaming(_, _): return
            }
        }
    }

    private func _beginStreaming(from fileDesc: FileDescriptor) throws -> FileSource {
        let workerQueue = DispatchQueue(label: "de.sersoft.filestreamer.worker")
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDesc.rawValue, queue: workerQueue)
        let rawSize = MemoryLayout<Value>.size
        var remainingData = 0
        source.setEventHandler { [unowned self] in
            do {
                remainingData += Int(source.data)
                guard case let capacity = remainingData / rawSize, capacity > 0 else { return }
                let buffer = UnsafeMutableBufferPointer<Value>.allocate(capacity: capacity)
                defer { buffer.deallocate() }
                let bytesRead = try fileDesc.read(into: UnsafeMutableRawBufferPointer(buffer))
                if case let noOfValues = bytesRead / rawSize, noOfValues > 0 {
                    let values = Array(buffer.prefix(noOfValues))
                    self.getStorageValue(for: \.callbacks.read).forEach { $0(self, values) }
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
        try withStorageValue(\.state) {
            guard case .streaming(let fileDesc, let source) = $0 else { return }
            try _endStreaming(of: source)
            $0 = .open(fileDesc)
        }
    }

    private func _endStreaming(of source: FileSource) throws {
        source.cancel()
    }

    public func close() throws {
        try withStorage {
            switch $0.state {
            case .closed: return
            case .streaming(let fileDesc, let source):
                try _endStreaming(of: source)
                fallthrough
            case .open(let fileDesc): try _close(fileDesc, informing: $0.callbacks.close)
            }
            $0.state = .closed
        }
    }

    private func _close(_ fileDesc: FileDescriptor, informing callbacks: Array<StateCallback<FileDescriptor>>) throws {
        try fileDesc.closeAfter { try callbacks.forEach { try $0(self, fileDesc) } }
    }
}
