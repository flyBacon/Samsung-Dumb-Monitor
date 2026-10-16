// SPDX-License-Identifier: MPL-2.0
import Foundation
import S9InputControl

func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}

func LF(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}

typealias MonitorCredentials = S9Credentials
typealias CredentialStore = S9CredentialStore
