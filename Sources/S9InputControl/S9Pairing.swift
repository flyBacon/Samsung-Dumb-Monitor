// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation
import Security

/// Setup is deliberately separate from normal control. `pair` can add a
/// persistent controller authorization and must follow an explicit user action.
public enum S9Pairing {
    enum Operation: String { case inspect = "getTVStates", pair = "createAccessToken" }

    public static func inspect(host: String) async throws -> String {
        let delegate = PairingTrust(host: host, expectedPin: nil)
        // An unauthenticated RPC error is expected here. This step observes
        // the certificate; it neither obtains nor proves control permission.
        _ = try await request(host: host, operation: .inspect, delegate: delegate, timeout: 6)
        guard let pin = delegate.observedPin else { throw S9InputError.invalidConfiguration }
        return pin
    }

    public static func pair(host: String, certificateSHA256: String) async throws -> String {
        let body = try await request(host: host, operation: .pair,
            delegate: PairingTrust(host: host, expectedPin: certificateSHA256), timeout: 45)
        return try token(from: body)
    }

    static func token(from body: Data) throws -> String {
        guard let value = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw PairingError.invalidResponse
        }
        if let code = (value["error"] as? [String: Any])?["code"] as? Int ?? value["code"] as? Int {
            throw PairingError.rejected(code)
        }
        guard value["error"] == nil, let result = value["result"] as? [String: Any],
              let token = result["AccessToken"] as? String, !token.isEmpty else {
            throw PairingError.invalidResponse
        }
        return token
    }

    static func makeRequest(host: String, operation: Operation) throws -> URLRequest {
        var url = URLComponents()
        url.scheme = "https"; url.host = host; url.port = 1516; url.path = "/"
        guard !host.isEmpty, let endpoint = url.url else { throw S9InputError.invalidConfiguration }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Required by Samsung IP Control: omitting Accept returns HTTP 400,
        // even though the body and Content-Type already specify JSON.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var payload: [String: Any] = ["jsonrpc": "2.0", "id": "1", "method": operation.rawValue]
        if operation == .inspect { payload["params"] = ["AccessToken": ""] }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    static func validatedBody(_ body: Data, response: URLResponse) throws -> Data {
        guard let response = response as? HTTPURLResponse else { throw PairingError.invalidResponse }
        guard response.statusCode == 200 else { throw S9InputError.http(response.statusCode) }
        guard body.count <= 262144 else { throw PairingError.invalidResponse }
        return body
    }

    private static func request(host: String, operation: Operation, delegate: PairingTrust, timeout: TimeInterval) async throws -> Data {
        let request = try makeRequest(host: host, operation: operation)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 2
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (body, response) = try await session.data(for: request)
        return try validatedBody(body, response: response)
    }
}

enum PairingError: LocalizedError {
    case invalidResponse
    case rejected(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            NSLocalizedString("S9 returned an invalid pairing response or no local token. Check the monitor's approval prompt.", bundle: .main, comment: "")
        case .rejected(let code):
            String(format: NSLocalizedString("S9 rejected pairing (code %d). Check the monitor's approval prompt and IP Remote setting.", bundle: .main, comment: ""), code)
        }
    }
}

private final class PairingTrust: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let host: String
    let expectedPin: String?
    private let lock = NSLock()
    private var pin: String?
    var observedPin: String? { lock.withLock { pin } }

    init(host: String, expectedPin: String?) { self.host = host; self.expectedPin = expectedPin?.lowercased() }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let actual = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        guard expectedPin == nil || actual == expectedPin else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        lock.withLock { pin = actual }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
