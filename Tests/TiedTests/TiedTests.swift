@testable import Tied
import XCTest

final class TiedTests: XCTestCase {
    func testDataIsCorrect() throws {
        let msg = CoAPMessage(code: .get, type: .confirmable, messageId: 0, token: 1)

        let data = try msg.encode()

        XCTAssert([UInt8](data) == [65, 1, 0, 0, 1])
    }

    func testDataWithOptionsIsCorrect() throws {
        let msg = CoAPMessage(code: .get, type: .confirmable, messageId: 0, token: 1, options: [.init(key: .ifNoneMatch, value: [5].withUnsafeBytes { Data($0) }), .init(key: .etag, value: [3].withUnsafeBytes { Data($0) }), .init(key: .observe, value: [10].withUnsafeBytes { Data($0) })])

        let data = try msg.encode()

        XCTAssert([UInt8](data) == [65, 1, 0, 0, 1, 72, 3, 0, 0, 0, 0, 0, 0, 0, 24, 5, 0, 0, 0, 0, 0, 0, 0, 24, 10, 0, 0, 0, 0, 0, 0, 0])
    }
}
