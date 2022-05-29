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
        let msg = CoAPMessage(code: CoAPMessage.Code.Method.get, type: .confirmable, messageId: 0, token: 1, options: [], payload: Data())
        
        let data = try msg.encode()
        
        XCTAssert([UInt8](data) == [65, 1, 0, 0, 1])
    }
}
