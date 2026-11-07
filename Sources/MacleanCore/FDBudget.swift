import Darwin
import os

/// A process-wide allowance of file descriptors shared by concurrent scans.
///
/// A scan holds at most two fds per in-flight read (while walking a reopen
/// chain) plus one per retained directory, so a grant costs
/// `2 × inFlight + retained`. Grants never drop below 2 in flight and 4
/// retained: when the budget is exhausted a scan overshoots slightly rather
/// than refusing to run. The floor overshoot can add up to 8 fds
/// (2 × 2 + 4) per extra concurrent scan.
///
/// A single grant's cost is also capped at `limit / 2` (but never below the
/// floor), so a second concurrent scan always gets a fair share instead of
/// the first one taking everything. `maclean-scan` raises its soft
/// `RLIMIT_NOFILE` to `min(hard, 10240)` at launch so the budget is sizeable.
final class FDBudget: Sendable {
    struct Grant: Sendable {
        let inFlight: Int
        let retained: Int
        var cost: Int { 2 * inFlight + retained }
    }

    static let minInFlight = 2
    static let minRetained = 4

    /// Half the soft `RLIMIT_NOFILE`, leaving the rest to the host process.
    static let shared: FDBudget = {
        var limit = rlimit()
        let soft = getrlimit(RLIMIT_NOFILE, &limit) == 0 ? Int(clamping: limit.rlim_cur) : 256
        return FDBudget(limit: soft / 2)
    }()

    private struct State {
        var outstanding = 0
        var highWater = 0
    }

    let limit: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(limit: Int) {
        self.limit = limit
    }

    /// Grants the desired amounts if they fit in what is left; otherwise
    /// scales both down proportionally, but never below the floor.
    func acquire(desiredInFlight: Int, desiredRetained: Int) -> Grant {
        let wantInFlight = max(Self.minInFlight, desiredInFlight)
        let wantRetained = max(Self.minRetained, desiredRetained)
        let wantCost = 2 * wantInFlight + wantRetained
        return state.withLock { s in
            let available = min(max(0, limit - s.outstanding), limit / 2)
            let grant: Grant
            if wantCost <= available {
                grant = Grant(inFlight: wantInFlight, retained: wantRetained)
            } else {
                grant = Grant(inFlight: max(Self.minInFlight, wantInFlight * available / wantCost),
                              retained: max(Self.minRetained, wantRetained * available / wantCost))
            }
            s.outstanding += grant.cost
            s.highWater = max(s.highWater, s.outstanding)
            return grant
        }
    }

    func release(_ grant: Grant) {
        state.withLock { $0.outstanding -= grant.cost }
    }

    /// The most fds ever granted at once.
    var highWater: Int { state.withLock { $0.highWater } }
}
