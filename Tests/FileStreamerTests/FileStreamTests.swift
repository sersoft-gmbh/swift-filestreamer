import XCTest
import SystemPackage
@testable import FileStreamer

final class FileStreamTests: XCTestCase {
    private struct TestValue: Equatable, CustomStringConvertible {
        let bool: CBool
        let int: CInt
        let dbl: CDouble

        var description: String {
            #"{"bool": \#(bool), "int": \#(int), "dbl": \#(dbl)}"#
        }
    }

    private func withTemporaryDirectory(do work: (URL) async throws -> ()) async throws {
        let newSubdir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: newSubdir, withIntermediateDirectories: true)
        try await work(newSubdir)
        try FileManager.default.removeItem(at: newSubdir)
    }

    func testSimpleStreaming() async throws {
        final actor Coordinator {
            private(set) var shouldStartWriting = false
            private(set) var hasFinishedWriting = false
            private(set) var hasFinishedReading = false

            var hasCompleted: Bool { hasFinishedWriting && hasFinishedReading }

            func readyForReceiving() {
                shouldStartWriting = true
            }

            func didFinishWriting() {
                hasFinishedWriting = true
            }

            func didFinishReading() {
                hasFinishedReading = true
            }
        }

        let expectedEvents: Array<TestValue> = [
            TestValue(bool: false, int: 1, dbl: 4.3),
            TestValue(bool: true, int: 2, dbl: 3.2),
            TestValue(bool: false, int: 42, dbl: 10.25),
        ]

        var collectedEvents = Array<TestValue>()
        try await withTemporaryDirectory { dir in
            let file = FilePath(dir.appendingPathComponent("streaming_file").path)
            let writingDesc = try FileDescriptor.open(file, .writeOnly,
                                                      options: [.create, .truncate],
                                                      permissions: [.ownerReadWrite, .groupReadWrite])
            let readingDesc = try FileDescriptor.open(file, .readOnly)
            let coordinator = Coordinator()
            let collectionTask = Task<(Array<TestValue>, Bool), any Error>.detached {
                let seq = FileStream<TestValue>(fileDescriptor: readingDesc)
                var collectedEvents = Array<TestValue>()
                var didReachEnd = false
                await coordinator.readyForReceiving()
                for try await elem in seq {
                    collectedEvents.append(elem)
                    if await coordinator.hasFinishedWriting && collectedEvents.count >= expectedEvents.count {
                        didReachEnd = true
                        break
                    }
                }
                if didReachEnd {
                    await coordinator.didFinishReading()
                }
                return (collectedEvents, didReachEnd)
            }
            let writeTask = Task.detached {
                while await !coordinator.shouldStartWriting {
                    try await Task.sleep(nanoseconds: 100)
                }
                for var event in expectedEvents {
                    do {
                        try withUnsafeBytes(of: &event) {
                            XCTAssertEqual(try writingDesc.write($0), MemoryLayout<TestValue>.size)
                        }
                        try await Task.sleep(nanoseconds: 10)
                    } catch {
                        XCTFail("writing failed: \(error)")
                    }
                }
                await coordinator.didFinishWriting()
                try writingDesc.close()
            }
            var waitedNanoseconds: UInt64 = 0
            while await !coordinator.hasCompleted && waitedNanoseconds < 10_000_000_000 {
                try await Task.sleep(nanoseconds: 100)
                waitedNanoseconds += 100
            }
            if await !coordinator.hasFinishedWriting {
                writeTask.cancel()
                XCTFail("Write didn't finish")
            }
            try await writeTask.value
            if await !coordinator.hasFinishedReading {
                collectionTask.cancel()
                XCTFail("Read didn't finish")
            }
            let (c, didReachEnd) = try await collectionTask.value
            collectedEvents = c
            XCTAssertTrue(didReachEnd)
            XCTAssertFalse(collectionTask.isCancelled)
            try readingDesc.close()
        }
        XCTAssertEqual(collectedEvents, expectedEvents)
    }
}
