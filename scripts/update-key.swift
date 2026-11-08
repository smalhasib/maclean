// Release signing key tool for Maclean updates (Ed25519, CryptoKit only).
//
//   swift scripts/update-key.swift generate <keyfile>      new key; refuses to overwrite; mode 0600
//   swift scripts/update-key.swift public <keyfile>        prints the base64 public key
//   swift scripts/update-key.swift sign <keyfile> <file>   writes <file>.sig (base64 of the raw 64-byte signature)
//
// The key file holds base64 of the private key's raw representation.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("Can't read an update key from \(path).") }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch (args.first, args.count) {
case ("generate", 2):
    let path = args[1]
    guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) already exists; refusing to overwrite it.") }
    let key = Curve25519.Signing.PrivateKey()
    let created = FileManager.default.createFile(
        atPath: path,
        contents: Data(key.rawRepresentation.base64EncodedString().utf8),
        attributes: [.posixPermissions: 0o600])
    guard created else { fail("Couldn't write \(path).") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case ("public", 2):
    print(loadKey(args[1]).publicKey.rawRepresentation.base64EncodedString())
case ("sign", 3):
    let key = loadKey(args[1])
    guard let data = FileManager.default.contents(atPath: args[2]) else { fail("Can't read \(args[2]).") }
    guard let signature = try? key.signature(for: data) else { fail("Signing failed.") }
    do {
        try Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: args[2] + ".sig"))
    } catch { fail("Couldn't write \(args[2]).sig.") }
default:
    fail("usage: update-key.swift generate <keyfile> | public <keyfile> | sign <keyfile> <file>")
}
