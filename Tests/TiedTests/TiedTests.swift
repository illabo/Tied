@testable import Tied
import XCTest

final class TiedTests: XCTestCase {
    func testDataIsCorrect() throws {
        let msg = CoAPMessage(code: .get, type: .confirmable, messageId: 0, token: 1)

        let data = try msg.encode()

        XCTAssert([UInt8](data) == [65, 1, 0, 0, 1])
    }

    func testDataWithOptionsIsCorrect() throws {
        let msg = CoAPMessage(code: .get, type: .confirmable, messageId: 0, token: 1, options: CoAPMessage.createOptionsSet([
            .ifNoneMatch: [5].withUnsafeBytes { Data($0) },
            .etag: [3].withUnsafeBytes { Data($0) },
            .observe: [10].withUnsafeBytes { Data($0) },
        ]))

        let data = try msg.encode()

        XCTAssert([UInt8](data) == [65, 1, 0, 0, 1, 72, 3, 0, 0, 0, 0, 0, 0, 0, 24, 5, 0, 0, 0, 0, 0, 0, 0, 24, 10, 0, 0, 0, 0, 0, 0, 0])
    }

    func testMessageDecoded() throws {
        let messageBytes: [UInt8] = [65, 1, 0, 0, 1, 72, 3, 0, 0, 0, 0, 0, 0, 0, 24, 5, 0, 0, 0, 0, 0, 0, 0, 24, 10, 0, 0, 0, 0, 0, 0, 0]
        let message = try messageBytes.withUnsafeBytes {
            try CoAPMessage.with($0)
        }
        XCTAssert(message.messageId == 0)
        XCTAssert(message.options.map(\.key) == [.etag, .ifNoneMatch, .observe])
        XCTAssert(message.options.map { [UInt8]($0.value).withUnsafeBytes { $0.load(as: Int.self) } } == [3, 5, 10])
    }

    func testMessageEncodePayload() throws {
        let msg = CoAPMessage(code: .get, type: .confirmable, messageId: 0, token: 1000, payload: "Hello, there!".data(using: .utf8) ?? Data())

        let data = try msg.encode()

        XCTAssert([UInt8](data) == [66, 1, 0, 0, 3, 232, 255, 72, 101, 108, 108, 111, 44, 32, 116, 104, 101, 114, 101, 33])
    }

    func testMessageDecodePayload() throws {
        let messageBytes: [UInt8] = [66, 1, 0, 0, 3, 232, 255, 72, 101, 108, 108, 111, 44, 32, 116, 104, 101, 114, 101, 33]
        let message = try messageBytes.withUnsafeBytes {
            try CoAPMessage.with($0)
        }

        XCTAssert(message.messageId == 0)
        XCTAssert(message.token == 1000)
        XCTAssert(String(bytes: message.payload, encoding: .utf8) == "Hello, there!")
    }
}
