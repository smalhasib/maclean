import Darwin
import Foundation

/// Process facts from libproc, for Smart Clean's "in use" checks (spec §6.3).
/// Processes this user may not inspect (other users', without root) are
/// passed over; nil means the process list itself couldn't be read.
public enum ProcessProbes {
    /// Whether any process has a file open at `path` or inside it. nil on failure.
    public static func pathsOpen(under path: String) -> Bool? {
        let root = ScanBoundary.canonicalPath(path) ?? path
        guard let pids = allPIDs() else { return nil }
        for pid in pids where openPaths(of: pid).contains(where: { PathUtil.isInside($0, orEqualTo: root) }) {
            return true
        }
        return false
    }

    /// Every inspectable process's current working directory. nil on failure.
    public static func workingDirectories() -> [String]? {
        guard let pids = allPIDs() else { return nil }
        return pids.compactMap { pid in
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
            let cwd = string(from: info.pvi_cdir.vip_path)
            return cwd.isEmpty ? nil : cwd
        }
    }

    /// Every inspectable process's name (`proc_name`). nil on failure.
    public static func processNames() -> [String]? {
        guard let pids = allPIDs() else { return nil }
        return pids.compactMap { pid in
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
            return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    // MARK: - libproc

    private static func allPIDs() -> [pid_t]? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return nil }
        return Array(pids.prefix(Int(n))).filter { $0 > 0 }
    }

    /// The paths of `pid`'s open vnode file descriptors; empty if it can't be inspected.
    private static func openPaths(of pid: pid_t) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return [] }
        return fds.prefix(Int(used) / stride).compactMap { fd in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
            let p = string(from: info.pvip.vip_path)
            return p.isEmpty ? nil : p
        }
    }

    private static func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}
