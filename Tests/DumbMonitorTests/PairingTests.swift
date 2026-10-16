// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import S9InputControl

@Test func bothFreshConnectionRequestsAdvertiseJSONAndKeepDistinctPayloads() throws {
    for operation in [S9Pairing.Operation.inspect, .pair] {
        let request = try S9Pairing.makeRequest(host: "monitor.local", operation: operation)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.port == 1516)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["method"] as? String == operation.rawValue)
        if operation == .inspect {
            #expect((payload["params"] as? [String: String]) == ["AccessToken": ""])
        } else {
            // The token bootstrap is a separate, explicitly approved action.
            #expect(payload["params"] == nil)
        }
    }
}

@Test func emptyHTTP400IsReportedAsHTTP400RatherThanUnknownRPCFailure() throws {
    let url = try #require(URL(string: "https://monitor.local:1516/"))
    let response = try #require(HTTPURLResponse(url: url, statusCode: 400, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/xml"]))
    do {
        _ = try S9Pairing.validatedBody(Data(), response: response)
        Issue.record("An HTTP error must not be accepted as a pairing response")
    } catch S9InputError.http(let status) {
        #expect(status == 400)
    }
}

@Test func pairingRejectsBothErrorFormatsAndNeverAcceptsAnErrorWithAToken() throws {
    let responses = [
        #"{"code":-32001,"message":"Denied"}"#,
        #"{"error":{"code":-32001,"message":"Denied"}}"#,
        #"{"error":{"code":-32001},"result":{"AccessToken":"test-token"}}"#,
    ]
    for text in responses {
        do {
            _ = try S9Pairing.token(from: Data(text.utf8))
            Issue.record("A denied pairing must not yield a token")
        } catch PairingError.rejected(let code) {
            #expect(code == -32001)
        }
    }
    #expect(try S9Pairing.token(from: Data(#"{"result":{"AccessToken":"test-token"}}"#.utf8)) == "test-token")
}

@Test func incompletePairingResponsesCannotBecomeSavedCredentials() {
    for text in ["", "not-json", "[]", "{}", #"{"result":{}}"#, #"{"result":{"AccessToken":""}}"#] {
        #expect(throws: PairingError.self) { try S9Pairing.token(from: Data(text.utf8)) }
    }
}
