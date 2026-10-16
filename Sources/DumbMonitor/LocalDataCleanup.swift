// SPDX-License-Identifier: MPL-2.0
import Foundation
import ServiceManagement
import S9InputControl

/// Dependencies are injected so cleanup tests never touch real credentials,
/// login items, preferences, files or a connected monitor.
@MainActor
struct LocalDataCleanup {
    enum Stage: Equatable {
        case loginItem, credentials, files, preferences

        var title: String {
            switch self {
            case .loginItem: L("Launch at login")
            case .credentials: L("Local pairing credentials")
            case .files: L("App cache files")
            case .preferences: L("App settings")
            }
        }
    }

    struct Failure: LocalizedError {
        let stage: Stage
        let underlying: any Error
        var errorDescription: String? {
            LF("Could not clear %@: %@", stage.title, underlying.localizedDescription)
        }
    }

    let stopControls: () async -> Void
    let disableLoginItem: () async throws -> Void
    let deleteCredentials: () throws -> Void
    let deleteFiles: () throws -> Void
    let deletePreferences: () throws -> Void

    func run() async throws {
        await stopControls()
        do { try await disableLoginItem() }
        catch { throw Failure(stage: .loginItem, underlying: error) }
        do { try deleteCredentials() }
        catch { throw Failure(stage: .credentials, underlying: error) }
        do { try deleteFiles() }
        catch { throw Failure(stage: .files, underlying: error) }
        do { try deletePreferences() }
        catch { throw Failure(stage: .preferences, underlying: error) }
    }

    static func production(stopControls: @escaping () async -> Void) -> Self {
        Self(stopControls: stopControls, disableLoginItem: {
            let service = SMAppService.mainApp
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                service.unregister { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }, deleteCredentials: {
            try S9CredentialStore.delete()
        }, deleteFiles: {
            let manager = FileManager.default
            let library = try manager.url(for: .libraryDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false)
            // Exact app-owned locations only. No search, glob or parent-folder
            // deletion; other apps and separate credential backups are untouched.
            for relative in ["Caches/local.dumb-monitor.app", "HTTPStorages/local.dumb-monitor.app",
                             "Saved Application State/local.dumb-monitor.app.savedState"] {
                let url = library.appendingPathComponent(relative)
                if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            }
        }, deletePreferences: {
            let identifier = "local.dumb-monitor.app"
            UserDefaults.standard.removePersistentDomain(forName: identifier)
            guard CFPreferencesAppSynchronize(identifier as CFString) else {
                throw PreferencesError()
            }
        })
    }

    private struct PreferencesError: LocalizedError {
        var errorDescription: String? { L("The settings removal could not be saved.") }
    }
}
