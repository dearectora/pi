import XCTest
@testable import WispAI

final class WispErrorTests: XCTestCase {

    func testInvalidURLDescription() {
        let err = WispError.invalidURL("not-a-url")
        XCTAssertTrue(err.errorDescription?.contains("not-a-url") == true)
    }

    func testHTTPErrorDescription() {
        let err = WispError.httpError(statusCode: 401, body: "Unauthorized")
        XCTAssertTrue(err.errorDescription?.contains("401") == true)
        XCTAssertTrue(err.errorDescription?.contains("Unauthorized") == true)
    }

    func testInvalidResponseDescription() {
        let err = WispError.invalidResponse
        XCTAssertNotNil(err.errorDescription)
    }
}
