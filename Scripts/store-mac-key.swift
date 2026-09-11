#!/usr/bin/env swift
import AppKit
import Foundation
import Security

// Store the key copied from OpenAI without putting it in shell arguments,
// environment variables, terminal output, files, or shell history.
let service = "com.dessdynamics.watchlearn.parent-secrets"
let account = "openai-api-key"
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
    kSecAttrSynchronizable as String: false
]
func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}
guard CommandLine.arguments.count == 1 else { fail("This helper takes no arguments.") }
guard SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound else {
    fail("Keychain item already exists or is unavailable; nothing was replaced.")
}
let clipboard = NSPasteboard.general
let revision = clipboard.changeCount
guard let value = clipboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
      value.hasPrefix("sk-"), (20...512).contains(value.count),
      value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
      let data = value.data(using: .utf8) else {
    fail("Copy a valid OpenAI API key first. No value was printed or stored.")
}
var item = query
item[kSecValueData as String] = data
item[kSecAttrLabel as String] = "ZeitHeld Family OpenAI API key"
let status = SecItemAdd(item as CFDictionary, nil)
guard status == errSecSuccess else { fail("Keychain storage failed (status \(status)).") }
if clipboard.changeCount == revision { clipboard.clearContents() }
print("ZeitHeld key saved in Mac Keychain; clipboard cleared. No key was printed.")
