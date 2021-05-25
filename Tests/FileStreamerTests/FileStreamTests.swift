import XCTest
import SystemPackage
@testable import FileStreamer

final class FileStreamTests: XCTestCase {
    private struct TestValue: Equatable {
        let bool: CBool
        let int: CInt
        let dbl: CDouble
    }

    private func withTemporaryDirectory(do work: (URL) throws -> ()) throws {
        let newSubdir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: newSubdir, withIntermediateDirectories: true)
        try work(newSubdir)
        try FileManager.default.removeItem(at: newSubdir)
    }

    func testSimpleStreaming() throws {
        let eventExpectation = expectation(description: "waiting for events")
        let expectedEvents: Array<TestValue> = [
            TestValue(bool: false, int: 1, dbl: 4.3),
            TestValue(bool: true, int: 2, dbl: 3.2),
            TestValue(bool: false, int: 42, dbl: 10.25),
        ]
        var collectedEvents: Array<TestValue> = []
        var callbackCount = 0
        try withTemporaryDirectory { dir in
            let file = FilePath(dir.appendingPathComponent("streaming_file").path)
            let writingDesc = try FileDescriptor.open(file, .writeOnly,
                                                      options: [.create, .truncate],
                                                      permissions: [.ownerReadWrite, .groupReadWrite])
            let stream = try FileStream<TestValue>(fileDescriptor: .open(file, .readOnly))
            stream.addCallback { stream, values in
                callbackCount += 1
                collectedEvents.append(contentsOf: values)
                if collectedEvents.count >= expectedEvents.count {
                    eventExpectation.fulfill()
                }
            }
            stream.beginStreaming()
            DispatchQueue.global().async {
                for var event in expectedEvents {
                    do {
                        try withUnsafeBytes(of: &event) {
                            XCTAssertEqual(try writingDesc.write($0), MemoryLayout<TestValue>.size)
                        }
                    } catch {
                        XCTFail("writing failed: \(error)")
                    }
                }
            }
            wait(for: [eventExpectation], timeout: 10)
            try writingDesc.close()
            try stream.fileDescriptor.closeAfter(stream.endStreaming)
        }
        XCTAssertEqual(collectedEvents, expectedEvents)
        XCTAssertLessThanOrEqual(callbackCount, expectedEvents.count)
    }
}
