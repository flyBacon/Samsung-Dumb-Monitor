// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import DumbMonitor

@MainActor
private final class CleanupTrace {
    var calls: [String] = []
    var failAt: String?
    func run(_ name: String) throws {
        calls.append(name)
        if failAt == name { throw NSError(domain: "CleanupTest", code: 1) }
    }
    var cleanup: LocalDataCleanup {
        LocalDataCleanup(stopControls: { self.calls.append("stop") },
            disableLoginItem: { try self.run("login") },
            deleteCredentials: { try self.run("credentials") },
            deleteFiles: { try self.run("files") },
            deletePreferences: { try self.run("preferences") })
    }
}

@Test @MainActor func cleanupStopsControlsBeforeDeletingCredentialsAndDeletesPreferencesLast() async throws {
    let trace = CleanupTrace()
    try await trace.cleanup.run()
    #expect(trace.calls == ["stop", "login", "credentials", "files", "preferences"])
}

@Test @MainActor func loginFailureLeavesCredentialsAndSettingsUntouched() async {
    let trace = CleanupTrace()
    trace.failAt = "login"
    do { try await trace.cleanup.run(); Issue.record("Cleanup must report login-item failure.") }
    catch let failure as LocalDataCleanup.Failure { #expect(failure.stage == .loginItem) }
    catch { Issue.record("Unexpected cleanup error: \(error)") }
    #expect(trace.calls == ["stop", "login"])
}

@Test @MainActor func credentialFailureDoesNotReportSuccessOrRemoveSettings() async {
    let trace = CleanupTrace()
    trace.failAt = "credentials"
    do { try await trace.cleanup.run(); Issue.record("Cleanup must report credential failure.") }
    catch let failure as LocalDataCleanup.Failure { #expect(failure.stage == .credentials) }
    catch { Issue.record("Unexpected cleanup error: \(error)") }
    #expect(trace.calls == ["stop", "login", "credentials"])
}

@Test @MainActor func fileAndPreferenceErrorsIdentifyTheIncompleteStep() async {
    for (step, stage) in [("files", LocalDataCleanup.Stage.files), ("preferences", .preferences)] {
        let trace = CleanupTrace()
        trace.failAt = step
        do { try await trace.cleanup.run(); Issue.record("Cleanup must report the failed step.") }
        catch let failure as LocalDataCleanup.Failure { #expect(failure.stage == stage) }
        catch { Issue.record("Unexpected cleanup error: \(error)") }
        #expect(trace.calls.last == step)
    }
}
