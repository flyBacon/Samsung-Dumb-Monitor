// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation
import S9InputControl

@main
struct S9InputCLI {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    static let usage = """
    Usage: s9-input <command>
      pair <monitor-address>   Pair on the LAN; approve on the monitor
      status                   Read input, audio and brightness
      usb-c | displayport      Select input directly
      input <protocol-value>   Select a custom source, e.g. HDMI1
      volume <0...100>          Set volume
      volume-up | volume-down  Adjust volume by 1
      mute | unmute            Set mute state
      brightness <0...50>      Set panel backlight
      brightness-up | brightness-down  Adjust backlight by 1

    Uses the same local token and certificate pin as Dumb Monitor, in Keychain.
    No account login or cloud API. --help does not read credentials or connect.
    """

    static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
            print(usage)
            return
        }
        let actions = ["status", "usb-c", "displayport", "input", "volume-up", "volume-down",
                       "volume", "mute", "unmute", "brightness-up", "brightness-down", "brightness"]
        guard let action = arguments.first else { return }
        if action == "pair" {
            guard arguments.count == 2 else { throw CLIError(usage) }
            let lock = try OperationLock()
            defer { lock.close() }
            try await pair(host: arguments[1])
            return
        }
        guard actions.contains(action) else { throw CLIError(usage) }
        let level: Int?
        let customInput: S9Input?
        if action == "input" {
            guard arguments.count == 2, let source = S9Input(rawValue: arguments[1]) else {
                throw CLIError("Supply one exact input source value, e.g. HDMI1 or 'Display Port'.")
            }
            customInput = source
            level = nil
        } else if action == "volume" || action == "brightness" {
            guard arguments.count == 2, let value = Int(arguments[1]),
                  (0...(action == "volume" ? 100 : 50)).contains(value) else {
                throw CLIError("Supply volume 0...100 or brightness 0...50.")
            }
            level = value
            customInput = nil
        } else {
            guard arguments.count == 1 else { throw CLIError(usage) }
            level = nil
            customInput = nil
        }
        let lock = try OperationLock()
        defer { lock.close() }
        guard let saved = try S9CredentialStore.load() else {
            throw CLIError("Not paired. Connect in Dumb Monitor or run: s9-input pair <monitor-address>")
        }
        let controller = try S9InputController(host: saved.host,
            accessToken: saved.token, certificateSHA256: saved.certificateSHA256)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let output: Data
        switch action {
        case "status":
            struct Status: Encodable { let input: S9Input; let audio: S9AudioState; let brightness: Int }
            output = try encoder.encode(await Status(input: controller.currentInput(),
                audio: controller.currentAudioState(), brightness: controller.currentBacklight()))
        case "volume-up": output = try encoder.encode(await controller.volumeUp())
        case "volume-down": output = try encoder.encode(await controller.volumeDown())
        case "volume": output = try encoder.encode(await controller.setVolume(level!))
        case "mute": output = try encoder.encode(await controller.mute())
        case "unmute": output = try encoder.encode(await controller.unmute())
        case "brightness-up": output = try encoder.encode(await controller.brightnessUp())
        case "brightness-down": output = try encoder.encode(await controller.brightnessDown())
        case "brightness": output = try encoder.encode(await controller.setBacklight(level!))
        case "input": output = try encoder.encode(await controller.setInput(customInput!))
        default:
            output = try encoder.encode(await controller.setInput(action == "usb-c" ? .usbC : .displayPort))
        }
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func pair(host: String) async throws {
        guard !host.isEmpty, !host.contains(where: { "/:@?#".contains($0) }) else {
            throw CLIError("Use the monitor's LAN IPv4 address or hostname, without a URL or port.")
        }
        let pin = try await S9Pairing.inspect(host: host)
        if var saved = try S9CredentialStore.load() {
            guard saved.certificateSHA256.lowercased() == pin else {
                throw CLIError("Certificate differs from the paired monitor. No token was sent or replaced.")
            }
            saved.host = host
            let controller = try S9InputController(host: host, accessToken: saved.token, certificateSHA256: pin)
            _ = try await controller.currentInput()
            try S9CredentialStore.save(saved)
            print("Existing local pairing verified; address updated.")
            return
        }
        print("Monitor: \(host)\nCertificate SHA-256: \(pin)")
        print("This trusts the LAN device and adds local control permission. Type PAIR to continue:", terminator: " ")
        guard readLine() == "PAIR" else { throw CLIError("Pairing cancelled.") }
        print("Choose Allow on the monitor when prompted.")
        let token = try await S9Pairing.pair(host: host, certificateSHA256: pin)
        let controller = try S9InputController(host: host, accessToken: token, certificateSHA256: pin)
        _ = try await controller.currentInput()
        try S9CredentialStore.save(S9Credentials(host: host, token: token, certificateSHA256: pin))
        print("Paired. Local credentials saved in Keychain.")
    }

    private struct CLIError: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }

    private final class OperationLock {
        private let descriptor: Int32
        init() throws {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("local.dumb-monitor.cli.lock").path
            let value = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard value >= 0 else { throw CLIError("Cannot open the local operation lock.") }
            guard flock(value, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(value)
                throw CLIError("Another CLI operation is running.")
            }
            descriptor = value
        }
        func close() { Darwin.close(descriptor) }
    }
}
