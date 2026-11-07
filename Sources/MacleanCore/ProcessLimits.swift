import Darwin

public enum ProcessLimits {
    /// Raises the soft `RLIMIT_NOFILE` to `min(hard, 10240)` (never lowers it), so the
    /// scanner's fd budget, which is a fraction of the limit, is large.
    public static func raiseOpenFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let wanted = min(limit.rlim_max, 10240)
        if wanted > limit.rlim_cur {
            limit.rlim_cur = wanted
            _ = setrlimit(RLIMIT_NOFILE, &limit)
        }
    }
}
