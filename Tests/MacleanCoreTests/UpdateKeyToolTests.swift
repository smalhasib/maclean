import CryptoKit
import Foundation
import Testing
@testable import MacleanCore

private func runSwift(_ args: [String], root: URL) -> (status: Int32, out: String)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["swift"] + args
    p.currentDirectoryURL = root
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

@Test func updateKeyToolRoundTrip() throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/swift") else { return }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let tool = root.appendingPathComponent("scripts/update-key.swift").path
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maclean-key-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let keyFile = dir.appendingPathComponent("key").path
    let file = dir.appendingPathComponent("Maclean-9.9.9.zip")
    let payload = Data("pretend zip".utf8)
    try payload.write(to: file)

    let gen = try #require(runSwift([tool, "generate", keyFile], root: root))
    #expect(gen.status == 0)
    let perms = try FileManager.default.attributesOfItem(atPath: keyFile)[.posixPermissions] as? Int
    #expect(perms == 0o600)
    let pub = try #require(runSwift([tool, "public", keyFile], root: root))
    #expect(pub.out == gen.out)
    #expect(runSwift([tool, "generate", keyFile], root: root)?.status != 0)  // never overwrites

    #expect(runSwift([tool, "sign", keyFile, file.path], root: root)?.status == 0)
    let sig = try String(contentsOfFile: file.path + ".sig", encoding: .utf8)
    #expect(Data(base64Encoded: sig)?.count == 64)
    #expect(UpdateSignature.isValid(payload, signatureBase64: sig, publicKeyBase64: pub.out))
    #expect(!UpdateSignature.isValid(Data("tampered".utf8), signatureBase64: sig, publicKeyBase64: pub.out))
}

@Test func embeddedKeyRejectsIdentityPointForgery() {
    // R = identity point (0x01, 0...), s = 0: a forgery that small-order keys accept.
    var forged = Data(repeating: 0, count: 64)
    forged[0] = 1
    #expect(!UpdateSignature.isValid(Data("anything".utf8), signatureBase64: forged.base64EncodedString(),
                                     publicKeyBase64: UpdateKey.publicKeyBase64))
}
