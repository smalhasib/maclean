import Foundation

public enum SizeText {
    /// File-style byte count, e.g. "306.6 GB" (decimal units, as Finder shows).
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
