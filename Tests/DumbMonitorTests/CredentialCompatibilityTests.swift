// SPDX-License-Identifier: MPL-2.0
import Foundation
import S9InputControl
import Testing

@Test func sharedCredentialTypePreservesExistingKeychainDataFormat() throws {
    // Synthetic values only; never load a real Keychain item during tests.
    let oldData = try JSONSerialization.data(withJSONObject: [
        "host": "monitor.invalid", "token": "test-only",
        "certificateSHA256": String(repeating: "0", count: 64),
    ])
    let restored = try JSONDecoder().decode(S9Credentials.self, from: oldData)
    #expect(restored.host == "monitor.invalid" && restored.token == "test-only")
    let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: String]
    #expect(roundTrip?.keys.sorted() == ["certificateSHA256", "host", "token"])
    #expect(roundTrip?["certificateSHA256"] == String(repeating: "0", count: 64))
}
