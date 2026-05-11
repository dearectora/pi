import XCTest
@testable import WispAI

// MARK: - DiagnosticErrorInfo

final class DiagnosticErrorInfoTests: XCTestCase {

    func testExtractFromWispHTTPError() {
        let error = WispError.httpError(statusCode: 429, body: "Too Many Requests")
        let info = DiagnosticErrorInfo.extract(from: error)

        XCTAssertEqual(info.code, "429")
        XCTAssertTrue(info.message.contains("429"))
        XCTAssertEqual(info.name, "WispError")
    }

    func testExtractFromWispInvalidURL() {
        let error = WispError.invalidURL("not-a-url")
        let info = DiagnosticErrorInfo.extract(from: error)

        XCTAssertNil(info.code)
        XCTAssertTrue(info.message.contains("not-a-url"))
    }

    func testExtractFromURLError() {
        let error = URLError(.notConnectedToInternet)
        let info = DiagnosticErrorInfo.extract(from: error)

        XCTAssertEqual(info.code, "\(URLError.Code.notConnectedToInternet.rawValue)")
        XCTAssertEqual(info.name, "URLError")
    }

    func testManualInit() {
        let info = DiagnosticErrorInfo(name: "MyError", message: "something broke", code: "E42")
        XCTAssertEqual(info.name,    "MyError")
        XCTAssertEqual(info.message, "something broke")
        XCTAssertEqual(info.code,    "E42")
    }

    func testPlainMessageInit() {
        let info = DiagnosticErrorInfo(message: "plain message")
        XCTAssertNil(info.name)
        XCTAssertNil(info.code)
        XCTAssertEqual(info.message, "plain message")
    }
}

// MARK: - AssistantMessageDiagnostic

final class AssistantMessageDiagnosticTests: XCTestCase {

    func testDefaultTimestampIsNow() {
        let before = Date()
        let diag = AssistantMessageDiagnostic(type: "test_event")
        let after = Date()

        XCTAssertGreaterThanOrEqual(diag.timestamp, before)
        XCTAssertLessThanOrEqual(diag.timestamp, after)
    }

    func testTypeAndDetailsStoredCorrectly() {
        let diag = AssistantMessageDiagnostic(
            type: "http_error",
            error: DiagnosticErrorInfo(message: "403"),
            details: ["statusCode": "403", "url": "https://example.com"]
        )
        XCTAssertEqual(diag.type, "http_error")
        XCTAssertEqual(diag.details["statusCode"], "403")
        XCTAssertEqual(diag.details["url"], "https://example.com")
    }

    func testNilErrorIsAllowed() {
        let diag = AssistantMessageDiagnostic(type: "info_event")
        XCTAssertNil(diag.error)
        XCTAssertTrue(diag.details.isEmpty)
    }
}

// MARK: - AssistantMessage.appendDiagnostic

final class AppendDiagnosticTests: XCTestCase {

    func testStartsEmpty() {
        let msg = AssistantMessage(model: "m", provider: "p")
        XCTAssertTrue(msg.diagnostics.isEmpty)
    }

    func testAppendErrorDiagnostic() {
        var msg = AssistantMessage(model: "m", provider: "p")
        msg.appendDiagnostic(
            type: "http_error",
            error: WispError.httpError(statusCode: 503, body: "Service Unavailable"),
            details: ["statusCode": "503"]
        )
        XCTAssertEqual(msg.diagnostics.count, 1)
        XCTAssertEqual(msg.diagnostics[0].type, "http_error")
        XCTAssertEqual(msg.diagnostics[0].error?.code, "503")
        XCTAssertEqual(msg.diagnostics[0].details["statusCode"], "503")
    }

    func testAppendMessageDiagnostic() {
        var msg = AssistantMessage(model: "m", provider: "p")
        msg.appendDiagnostic(type: "no_response_queued", message: "Queue was empty")
        XCTAssertEqual(msg.diagnostics.count, 1)
        XCTAssertEqual(msg.diagnostics[0].error?.message, "Queue was empty")
        XCTAssertNil(msg.diagnostics[0].error?.code)
    }

    func testAppendMultipleDiagnostics() {
        var msg = AssistantMessage(model: "m", provider: "p")
        msg.appendDiagnostic(type: "first",  message: "one")
        msg.appendDiagnostic(type: "second", message: "two")
        XCTAssertEqual(msg.diagnostics.count, 2)
        XCTAssertEqual(msg.diagnostics[0].type, "first")
        XCTAssertEqual(msg.diagnostics[1].type, "second")
    }

    func testDiagnosticsInitParameter() {
        let diag = AssistantMessageDiagnostic(type: "preexisting")
        let msg = AssistantMessage(model: "m", provider: "p", diagnostics: [diag])
        XCTAssertEqual(msg.diagnostics.count, 1)
        XCTAssertEqual(msg.diagnostics[0].type, "preexisting")
    }
}

// MARK: - Diagnostics via FauxProvider

final class FauxProviderDiagnosticsTests: XCTestCase {

    func testEmptyQueueAttachesDiagnostic() async {
        let faux = FauxProvider()
        let result = await faux.complete(context: Context())

        XCTAssertEqual(result.stopReason, .error)
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.diagnostics[0].type, "no_response_queued")
        XCTAssertEqual(result.diagnostics[0].details["callCount"], "1")
    }

    func testCallCountInDiagnosticReflectsActualCall() async {
        let faux = FauxProvider()
        await faux.setResponses([.message(FauxProvider.response(text: "ok"))])
        _ = await faux.complete(context: Context())   // call 1 — consumes the response
        let result = await faux.complete(context: Context())  // call 2 — queue empty

        XCTAssertEqual(result.diagnostics.first?.details["callCount"], "2")
    }

    func testErrorStopReasonAttachesDiagnostic() async {
        let faux = FauxProvider()
        await faux.setResponses([.message(
            FauxProvider.response(text: "", stopReason: .error, errorMessage: "upstream fail")
        )])
        let result = await faux.complete(context: Context())

        XCTAssertEqual(result.stopReason, .error)
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.diagnostics[0].type, "faux_error")
        XCTAssertEqual(result.diagnostics[0].error?.message, "upstream fail")
    }

    func testSuccessfulResponseHasNoDiagnostics() async {
        let faux = FauxProvider()
        await faux.setResponses([.message(FauxProvider.response(text: "all good"))])
        let result = await faux.complete(context: Context())

        XCTAssertEqual(result.stopReason, .stop)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testDiagnosticCarriedInErrorEvent() async {
        let faux = FauxProvider()

        var errorEvent: AssistantMessageEvent?
        for await event in await faux.stream(context: Context()) {
            if case .error = event { errorEvent = event }
        }

        if case .error(let msg) = errorEvent {
            XCTAssertFalse(msg.diagnostics.isEmpty)
            XCTAssertEqual(msg.diagnostics.first?.type, "no_response_queued")
        } else {
            XCTFail("Expected .error event from empty-queue stream")
        }
    }

    func testExplicitDiagnosticsPreservedFromFactory() async {
        let faux = FauxProvider()
        await faux.setResponses([.factory { _, _, _ in
            var msg = FauxProvider.response(text: "", stopReason: .error, errorMessage: "custom")
            // Pre-attach a diagnostic inside the factory to verify it is not overwritten.
            msg.appendDiagnostic(type: "custom_diag", message: "pre-attached")
            return msg
        }])
        let result = await faux.complete(context: Context())

        XCTAssertTrue(result.diagnostics.contains { $0.type == "custom_diag" })
        // FauxProvider should NOT add a second diagnostic when one already exists.
        XCTAssertEqual(result.diagnostics.count, 1)
    }
}
