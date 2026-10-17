// SPDX-License-Identifier: MPL-2.0
import S9InputControl

struct MonitorAudio: Sendable {
    let volume: Int
    let isMuted: Bool
}

protocol MonitorTransport: Sendable {
    func currentPower() async throws -> S9PowerState
    func setPower(_ state: S9PowerState) async throws -> S9PowerState
    func currentInput() async throws -> S9Input
    func currentAudioState() async throws -> MonitorAudio
    func currentBacklight() async throws -> Int
    func setInput(_ input: S9Input) async throws -> S9Input
    func setVolume(_ volume: Int) async throws -> MonitorAudio
    func setMuted(_ muted: Bool) async throws -> MonitorAudio
    func setBacklight(_ level: Int) async throws -> Int
}

struct LANMonitor: MonitorTransport {
    private let client: S9InputController

    init(_ credentials: MonitorCredentials) throws {
        client = try S9InputController(host: credentials.host, accessToken: credentials.token,
            certificateSHA256: credentials.certificateSHA256)
    }
    func currentPower() async throws -> S9PowerState { try await client.currentPower() }
    func setPower(_ state: S9PowerState) async throws -> S9PowerState { try await client.setPower(state) }
    func currentInput() async throws -> S9Input { try await client.currentInput() }
    func currentBacklight() async throws -> Int { try await client.currentBacklight() }
    func currentAudioState() async throws -> MonitorAudio {
        let state = try await client.currentAudioState()
        return MonitorAudio(volume: state.volume, isMuted: state.isMuted)
    }
    func setInput(_ input: S9Input) async throws -> S9Input { try await client.setInput(input).current }
    func setVolume(_ volume: Int) async throws -> MonitorAudio {
        let state = try await client.setVolume(volume).state
        return MonitorAudio(volume: state.volume, isMuted: state.isMuted)
    }
    func setMuted(_ muted: Bool) async throws -> MonitorAudio {
        let state = try await client.setMuted(muted).state
        return MonitorAudio(volume: state.volume, isMuted: state.isMuted)
    }
    func setBacklight(_ level: Int) async throws -> Int { try await client.setBacklight(level).backlight }
}
