// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import S9InputControl

private final class PowerStub: @unchecked Sendable {
    let lock = NSLock()
    var requests: [URLRequest] = []
    let replies: [String]
    init(_ replies: [String]) { self.replies = replies }
    func response(_ request: URLRequest) -> Data {
        lock.withLock {
            let index = requests.count
            requests.append(request)
            return Data((replies.indices.contains(index) ? replies[index] : "{}").utf8)
        }
    }
    var captured: [URLRequest] { lock.withLock { requests } }
}

private final class PowerStubRegistry: @unchecked Sendable {
    let lock = NSLock()
    var stubs: [URL: PowerStub] = [:]
    func set(_ stub: PowerStub?, for url: URL) { lock.withLock { stubs[url] = stub } }
    func get(_ url: URL) -> PowerStub? { lock.withLock { stubs[url] } }
}

private final class PowerURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = PowerStubRegistry()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "monitor.local" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let stub = Self.registry.get(url),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        // URLSession turns upload bodies into streams before URLProtocol sees
        // them. Capture the bytes actually delivered to this transport.
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
            captured.httpBody = body
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.response(captured))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func client(replies: [String]) -> (S9InputController, PowerStub, URL) {
    let endpoint = URL(string: "https://monitor.local/\(UUID().uuidString)")!
    let stub = PowerStub(replies)
    PowerURLProtocol.registry.set(stub, for: endpoint)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PowerURLProtocol.self]
    return (S9InputController(endpoint: endpoint, accessToken: "test-token", session: URLSession(configuration: configuration)), stub, endpoint)
}

@Test func powerSetterUsesOneAcknowledgedRequestAndGetterOmitsTheSetter() async throws {
    let (controller, stub, endpoint) = client(replies: [
        #"{"result":{"power":"powerOn"}}"#, #"{"result":{"power":"powerOff"}}"#
    ])
    defer { PowerURLProtocol.registry.set(nil, for: endpoint) }
    #expect(try await controller.setPower(.on) == .on)
    #expect(stub.captured.count == 1) // No separate polling after the setter.
    #expect(try await controller.currentPower() == .off)
    let requests = stub.captured
    #expect(requests.count == 2)
    for (index, request) in requests.enumerated() {
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        #expect(body?["method"] as? String == "powerControl")
        let parameters = body?["params"] as? [String: String]
        #expect(parameters?["AccessToken"] == "test-token")
        #expect(parameters?["power"] == (index == 0 ? "powerOn" : nil))
    }
}

@Test func incorrectOrMissingPowerAcknowledgementDoesNotPassOrRetry() async {
    for reply in [#"{"result":{"power":"powerOff"}}"#, #"{"result":{}}"#, #"{"error":{"code":-32002}}"#] {
        let (controller, stub, endpoint) = client(replies: [reply])
        do { _ = try await controller.setPower(.on); Issue.record("A failed wake must not be accepted.") }
        catch { #expect(stub.captured.count == 1) }
        PowerURLProtocol.registry.set(nil, for: endpoint)
    }
}
