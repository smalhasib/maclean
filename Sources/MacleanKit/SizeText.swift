import Foundation

public enum SizeText {
    /// File-style byte count, e.g. "306.6 GB" (decimal units, as Finder shows).
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The same count with the unit spelled out, for VoiceOver:
    /// "306.6 gigabytes", "0 bytes".
    public static func spoken(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        let text = formatter.string(fromByteCount: bytes)
        guard let space = text.lastIndex(where: { $0 == " " || $0 == "\u{00A0}" }) else { return text }
        let unit = String(text[text.index(after: space)...])
        guard let word = spokenUnits[unit] else { return text }
        let number = text[..<space]
        return "\(number) \(number == "1" && unit != "bytes" && unit != "byte" ? String(word.dropLast()) : word)"
    }

    private static let spokenUnits = [
        "byte": "byte", "bytes": "bytes", "KB": "kilobytes", "MB": "megabytes", "GB": "gigabytes",
        "TB": "terabytes", "PB": "petabytes", "EB": "exabytes",
    ]
}
