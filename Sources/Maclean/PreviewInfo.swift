import Darwin
import Foundation
import UniformTypeIdentifiers

/// What the preview pane says about a file under its preview.
struct PreviewInfo: Equatable {
    let name: String
    /// Finder-style kind: "Plain text document", "MPEG-4 movie".
    let kind: String
    let size: Int64
    let modified: Date?

    /// The file at `path`, only if it is a regular file: a symlink isn't followed, and a
    /// FIFO or device is refused, since previewing it could block.
    static func read(path: String) -> PreviewInfo? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension
        let described = UTType(filenameExtension: ext)?.localizedDescription
            ?? (ext.isEmpty ? "Document" : "\(ext.uppercased()) file")
        let kind = described.prefix(1).uppercased() + described.dropFirst()   // "text" → "Text"
        return PreviewInfo(name: url.lastPathComponent, kind: kind, size: Int64(st.st_size),
                           modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
    }
}
