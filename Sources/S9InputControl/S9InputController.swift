// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation
import Security

public struct S9Input: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public static let usbC = S9Input(rawValue: "USB-C")!
    public static let displayPort = S9Input(rawValue: "Display Port")!

    /// Protocol values are case-sensitive. Do not guess or rename HDMI ports.
    public init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 128,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let input = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid input source value")
        }
        self = input
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum S9PowerState: String, Codable, Sendable {
    case on = "powerOn", off = "powerOff"
}

public struct S9InputSwitchResult: Codable, Sendable {
    public let target: S9Input
    public let current: S9Input
    public let commandMilliseconds: Int
    public let stateObservedMilliseconds: Int
}

public struct S9AudioState: Codable, Sendable {
    public let volume: Int
    public let isMuted: Bool
}

public struct S9AudioChangeResult: Codable, Sendable {
    public let state: S9AudioState
    public let commandMilliseconds: Int
    public let stateObservedMilliseconds: Int
}

public struct S9BacklightChangeResult: Codable, Sendable {
    public let backlight: Int
    public let commandMilliseconds: Int
    public let stateObservedMilliseconds: Int
}

public enum S9InputError: Error, LocalizedError, Sendable {
    case invalidConfiguration
    case busy
    case http(Int)
    case protocolFailure(Int?)
    case unexpectedInput
    case unexpectedState
    case invalidValue
    case stateUnconfirmed

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: NSLocalizedString("Invalid S9 host, token, or certificate fingerprint.", bundle: .main, comment: "")
        case .busy: NSLocalizedString("A display operation is already in progress.", bundle: .main, comment: "")
        case .http(let status): String(format: NSLocalizedString("S9 returned HTTP %d; no command was retried.", bundle: .main, comment: ""), status)
        case .protocolFailure(let code): String(format: NSLocalizedString("S9 rejected the request (code %@). No automatic pairing was attempted.", bundle: .main, comment: ""), code.map(String.init) ?? "unknown")
        case .unexpectedInput: NSLocalizedString("S9 returned an unknown input; no source value was guessed.", bundle: .main, comment: "")
        case .unexpectedState: NSLocalizedString("S9 returned an unexpected power, volume, mute, or backlight state.", bundle: .main, comment: "")
        case .invalidValue: NSLocalizedString("Volume must be 0...100; backlight 0...50; relative steps must be positive.", bundle: .main, comment: "")
        case .stateUnconfirmed: NSLocalizedString("Command returned, but the target state was not observed. No command was retried.", bundle: .main, comment: "")
        }
    }
}

/// Uses a previously approved local controller token. Supply it from Keychain
/// in the host app. Pairing, Cloud login, and token persistence are not performed.
public actor S9InputController {
    private let endpoint: URL
    private let accessToken: String
    private let session: URLSession
    private var selecting = false

    public init(host: String, accessToken: String, certificateSHA256: String) throws {
        let pin = certificateSHA256.lowercased()
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = 1516
        components.path = "/"
        guard !host.isEmpty, !accessToken.isEmpty, pin.count == 64,
              pin.allSatisfy({ "0123456789abcdef".contains($0) }),
              let endpoint = components.url else { throw S9InputError.invalidConfiguration }
        self.endpoint = endpoint
        self.accessToken = accessToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = [:]
        self.session = URLSession(configuration: configuration,
            delegate: PinnedS9Delegate(host: host, sha256: pin), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    // Internal injection for protocol tests; the public initializer always
    // creates its own certificate-pinned session.
    init(endpoint: URL, accessToken: String, session: URLSession) {
        self.endpoint = endpoint
        self.accessToken = accessToken
        self.session = session
    }

    public func currentInput() async throws -> S9Input {
        try await request(input: nil)
    }

    public func currentPower() async throws -> S9PowerState {
        guard let raw = try await rpc("powerControl").power,
              let state = S9PowerState(rawValue: raw) else { throw S9InputError.unexpectedState }
        return state
    }

    /// One direct request. Validate the acknowledgement without extra polling
    /// or waiting for the panel to illuminate before a subsequent input command.
    @discardableResult
    public func setPower(_ state: S9PowerState) async throws -> S9PowerState {
        guard !selecting else { throw S9InputError.busy }
        selecting = true
        defer { selecting = false }
        let value = try await rpc("powerControl", extra: ["power": .text(state.rawValue)])
        guard value.power == state.rawValue else { throw S9InputError.stateUnconfirmed }
        return state
    }

    public func currentAudioState() async throws -> S9AudioState {
        let volume = try await currentVolume()
        let value = try await rpc("muteControl")
        guard let mute = value.mute, ["muteOn", "muteOff"].contains(mute) else {
            throw S9InputError.unexpectedState
        }
        return S9AudioState(volume: volume, isMuted: mute == "muteOn")
    }

    public func currentVolume() async throws -> Int {
        let value = try await rpc("directVolumeControl")
        guard let volume = value.volume, (0...100).contains(volume) else {
            throw S9InputError.unexpectedState
        }
        return volume
    }

    public func currentBacklight() async throws -> Int {
        let value = try await rpc("backlightControl")
        guard let backlight = value.backlight, (0...50).contains(backlight) else {
            throw S9InputError.unexpectedState
        }
        return backlight
    }

    @discardableResult
    public func setVolume(_ volume: Int) async throws -> S9AudioChangeResult {
        guard (0...100).contains(volume) else { throw S9InputError.invalidValue }
        guard !selecting else { throw S9InputError.busy }
        selecting = true
        defer { selecting = false }
        let start = ProcessInfo.processInfo.systemUptime
        return try await applyAudio("directVolumeControl", extra: ["volume": .number(volume)],
            expectedVolume: volume, start: start)
    }

    @discardableResult
    public func volumeUp(by step: Int = 1) async throws -> S9AudioChangeResult {
        guard (1...100).contains(step) else { throw S9InputError.invalidValue }
        return try await adjustVolume(by: step)
    }

    @discardableResult
    public func volumeDown(by step: Int = 1) async throws -> S9AudioChangeResult {
        guard (1...100).contains(step) else { throw S9InputError.invalidValue }
        return try await adjustVolume(by: -step)
    }

    private func adjustVolume(by delta: Int) async throws -> S9AudioChangeResult {
        guard !selecting else { throw S9InputError.busy }
        selecting = true
        defer { selecting = false }
        let start = ProcessInfo.processInfo.systemUptime
        let current = try await currentVolume()
        let target = min(100, max(0, current + delta))
        return try await applyAudio("directVolumeControl", extra: ["volume": .number(target)],
            expectedVolume: target, start: start)
    }

    @discardableResult
    public func setMuted(_ muted: Bool) async throws -> S9AudioChangeResult {
        guard !selecting else { throw S9InputError.busy }
        selecting = true
        defer { selecting = false }
        let start = ProcessInfo.processInfo.systemUptime
        return try await applyAudio("muteControl", extra: ["mute": .text(muted ? "muteOn" : "muteOff")],
            expectedMute: muted, start: start)
    }

    @discardableResult
    public func mute() async throws -> S9AudioChangeResult { try await setMuted(true) }

    @discardableResult
    public func unmute() async throws -> S9AudioChangeResult { try await setMuted(false) }

    private func applyAudio(_ method: String, extra: [String: RPCValue],
                            expectedVolume: Int? = nil, expectedMute: Bool? = nil,
                            start: TimeInterval) async throws -> S9AudioChangeResult {
        _ = try await rpc(method, extra: extra)
        let accepted = elapsedMilliseconds(since: start)
        for delay in [0, 150, 400, 900, 1800] {
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            let state = try await currentAudioState()
            if (expectedVolume == nil || state.volume == expectedVolume)
                && (expectedMute == nil || state.isMuted == expectedMute) {
                return S9AudioChangeResult(state: state, commandMilliseconds: accepted,
                    stateObservedMilliseconds: elapsedMilliseconds(since: start))
            }
        }
        throw S9InputError.stateUnconfirmed
    }

    /// Raw panel brightness scale 0...50 on the tested S9. This uses
    /// backlightControl, not brightnessControl (a different picture parameter).
    @discardableResult
    public func setBacklight(_ level: Int) async throws -> S9BacklightChangeResult {
        guard (0...50).contains(level) else { throw S9InputError.invalidValue }
        guard !selecting else { throw S9InputError.busy }
        selecting = true
        defer { selecting = false }
        return try await applyBacklight(level, start: ProcessInfo.processInfo.systemUptime)
    }

    @discardableResult
    public func brightnessUp(by step: Int = 1) async throws -> S9BacklightChangeResult {
        guard (1...50).contains(step) else { throw S9InputError.invalidValue }
        return try await adjustBacklight(by: step)
    }

    @discardableResult
    public func brightnessDown(by step: Int = 1) async throws -> S9BacklightChangeResult {
        guard (1...50).contains(step) else { throw S9InputError.invalidValue }
        return try await adjustBacklight(by: -step)
    }

    private func adjustBacklight(by delta: Int) async throws -> S9BacklightChangeResult {
        guard !selecting else { throw S9InputError.busy }
        selecting = true
        defer { selecting = false }
        let start = ProcessInfo.processInfo.systemUptime
        let current = try await currentBacklight()
        return try await applyBacklight(min(50, max(0, current + delta)), start: start)
    }

    private func applyBacklight(_ level: Int, start: TimeInterval) async throws -> S9BacklightChangeResult {
        _ = try await rpc("backlightControl", extra: ["backlight": .number(level)])
        let accepted = elapsedMilliseconds(since: start)
        for delay in [0, 150, 400, 900, 1800] {
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            let current = try await currentBacklight()
            if current == level {
                return S9BacklightChangeResult(backlight: current, commandMilliseconds: accepted,
                    stateObservedMilliseconds: elapsedMilliseconds(since: start))
            }
        }
        throw S9InputError.stateUnconfirmed
    }

    /// Sends exactly one direct setter and polls the local getter. Matching
    /// state is not a measurement of physical panel illumination time.
    @discardableResult
    public func setInput(_ input: S9Input) async throws -> S9InputSwitchResult {
        guard !selecting else { throw S9InputError.busy }
        selecting = true
        defer { selecting = false }
        let start = ProcessInfo.processInfo.systemUptime
        _ = try await request(input: input)
        let accepted = elapsedMilliseconds(since: start)
        for waitMilliseconds in [0, 150, 400, 900, 1800] {
            if waitMilliseconds > 0 {
                try await Task.sleep(for: .milliseconds(waitMilliseconds))
            }
            let current = try await currentInput()
            if current == input {
                return S9InputSwitchResult(target: input, current: current,
                    commandMilliseconds: accepted,
                    stateObservedMilliseconds: elapsedMilliseconds(since: start))
            }
        }
        throw S9InputError.stateUnconfirmed
    }

    private func elapsedMilliseconds(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }

    private enum RPCValue: Encodable {
        case text(String)
        case number(Int)
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text): try container.encode(text)
            case .number(let number): try container.encode(number)
            }
        }
    }

    private struct RPCRequest: Encodable {
        let jsonrpc = "2.0"
        let id = "1"
        let method: String
        let params: [String: RPCValue]
    }

    private struct RPCResponse: Decodable {
        let result: ResultValue?
        let error: ErrorValue?
        let code: Int?
        struct ResultValue: Decodable {
            let power: String?
            let inputSource: String?
            let volume: Int?
            let mute: String?
            let backlight: Int?
        }
        struct ErrorValue: Decodable { let code: Int? }
    }

    private func request(input: S9Input?) async throws -> S9Input {
        let parameters: [String: RPCValue] = input.map { ["inputSource": .text($0.rawValue)] } ?? [:]
        let result = try await rpc("inputSourceControl", extra: parameters)
        guard let rawInput = result.inputSource, let source = S9Input(rawValue: rawInput) else {
            throw S9InputError.unexpectedInput
        }
        return source
    }

    private func rpc(_ method: String, extra: [String: RPCValue] = [:]) async throws -> RPCResponse.ResultValue {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var parameters = extra
        parameters["AccessToken"] = .text(accessToken)
        request.httpBody = try JSONEncoder().encode(RPCRequest(method: method, params: parameters))
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw S9InputError.protocolFailure(nil) }
        guard http.statusCode == 200 else { throw S9InputError.http(http.statusCode) }
        guard body.count <= 262144 else { throw S9InputError.protocolFailure(nil) }
        let value = try JSONDecoder().decode(RPCResponse.self, from: body)
        guard value.error == nil, value.code == nil, let result = value.result else {
            throw S9InputError.protocolFailure(value.error?.code ?? value.code)
        }
        return result
    }
}

/// The panel presents a private/self-signed certificate. Trust only the exact
/// certificate observed during approved setup; reject replacement and redirects
/// so a controller token is never forwarded to a different endpoint.
private final class PinnedS9Delegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let host: String
    let sha256: String
    init(host: String, sha256: String) { self.host = host; self.sha256 = sha256 }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let data = SecCertificateCopyData(certificate) as Data
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == sha256 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

}
