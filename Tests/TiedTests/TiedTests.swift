import XCTest
@testable import Tied

final class TiedTests: XCTestCase {
    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
//        XCTAssertEqual(Tied().text, "Hello, World!")
    }
    
    func testDataIsCorrect() throws {
        let msg = CoAPMessage(code: .get, type: .confirmable, messageId: 0, token: 1)
        
        let data = try msg.encode()
        
        XCTAssert([UInt8](data) == [65, 1, 0, 0, 1])
    }
}
