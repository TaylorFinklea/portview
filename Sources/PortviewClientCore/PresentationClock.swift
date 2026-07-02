/// Maps media presentation timestamps from the host's timeline onto the client's local timeline.
///
/// **Sign convention** — `hostClockOffsetMicros` is the host clock reading minus the local clock
/// reading at the same instant: `host = local + offset`, i.e. `offset = hostMicros − localMicros`.
/// It is derived externally from the Ping/Pong exchange (`Pong.hostUptimeMicros` vs the midpoint of
/// the Ping's local send/receive times) — this type never reads a clock itself; every time is a
/// parameter.
///
/// A frame stamped `ptsMicros` on the host timeline therefore corresponds to local instant
/// `ptsMicros − offset`, and its target present time adds a fixed presentation delay (the jitter
/// headroom that lets network-delayed frames still arrive before their moment on screen):
///
///     target = ptsMicros − hostClockOffsetMicros + presentationDelayMicros
///
/// The mapping is a pure translation, so for a fixed offset it is strictly monotonic in PTS
/// (non-strict only at the saturated extremes of Int64, far outside any realistic uptime).
///
/// The clock decides WHEN a frame is due; the renderer keeps deciding WHERE it draws.
public struct PresentationClock: Sendable, Equatable {
    /// Host clock minus local clock, in microseconds (`host = local + offset`). Refine it in place
    /// as new Ping/Pong samples arrive — the buffer re-reads it on every insert/pop.
    public var hostClockOffsetMicros: Int64
    /// Fixed jitter headroom added to every mapped time, in microseconds.
    public let presentationDelayMicros: Int64

    public init(hostClockOffsetMicros: Int64, presentationDelayMicros: Int64 = 50_000) {
        precondition(presentationDelayMicros >= 0, "presentation delay is jitter headroom; it cannot be negative")
        self.hostClockOffsetMicros = hostClockOffsetMicros
        self.presentationDelayMicros = presentationDelayMicros
    }

    /// The local-timeline instant (microseconds) at which media stamped `ptsMicros` (host timeline)
    /// should be presented.
    public func targetPresentTimeMicros(forPTSMicros ptsMicros: UInt64) -> Int64 {
        Int64(clamping: ptsMicros)
            .saturatingSubtracting(hostClockOffsetMicros)
            .saturatingAdding(presentationDelayMicros)
    }
}

/// A bounded, PTS-keyed jitter buffer: media elements wait here until their
/// ``PresentationClock`` target present time arrives on the local timeline.
///
/// Designed for one instance per stream (the m-present follow-on holds a `PTSJitterBuffer<VideoFrame>`
/// and a `PTSJitterBuffer<AudioFrame>` sharing one clock value) — the shared monotonic mapping keeps
/// cross-stream pop order equal to global PTS order.
///
/// **Drop policies** (both observable for diagnostics):
/// - **Capacity, oldest-first**: when an insert pushes the buffer past `capacity`, the entry with
///   the lowest PTS is evicted (which is the incoming element itself if it carries the lowest PTS)
///   and counted in ``droppedOverflow``.
/// - **Late budget**: an element whose target present time is already *more than* `lateBudgetMicros`
///   in the past — at insert time or at pop time — is dropped and counted in ``droppedLate``.
///   Exactly `lateBudgetMicros` late is still kept.
public struct PTSJitterBuffer<Element: Sendable>: Sendable {
    private struct Entry {
        let pts: UInt64
        let element: Element
    }

    /// Shared timeline mapping. Mutable so a refined Ping/Pong offset can be applied to a live buffer.
    public var clock: PresentationClock
    /// Maximum number of buffered elements; exceeding it evicts oldest-first.
    public let capacity: Int
    /// How far past its target present time an element may be (at insert or pop) before it is dropped.
    public let lateBudgetMicros: Int64
    /// Elements dropped for being more than ``lateBudgetMicros`` past their target present time.
    public private(set) var droppedLate: Int = 0
    /// Elements evicted oldest-first to keep the buffer within ``capacity``.
    public private(set) var droppedOverflow: Int = 0

    /// Entries kept sorted by PTS ascending (insertion order preserved among equal PTS values).
    private var entries: [Entry] = []

    public init(clock: PresentationClock, capacity: Int, lateBudgetMicros: Int64) {
        precondition(capacity >= 1, "a jitter buffer needs room for at least one element")
        precondition(lateBudgetMicros >= 0, "the late budget is a grace period; it cannot be negative")
        self.clock = clock
        self.capacity = capacity
        self.lateBudgetMicros = lateBudgetMicros
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// Target present time of the lowest-PTS buffered element (what a render loop should schedule
    /// its next wake for), or nil when empty.
    public var nextTargetPresentTimeMicros: Int64? {
        entries.first.map { clock.targetPresentTimeMicros(forPTSMicros: $0.pts) }
    }

    /// Stages an element for presentation. Returns false when the element was not retained —
    /// already more than ``lateBudgetMicros`` past its target at `nowMicros` (counted in
    /// ``droppedLate``), or immediately evicted as the oldest entry of an over-capacity buffer
    /// (counted in ``droppedOverflow``).
    @discardableResult
    public mutating func insert(pts: UInt64, element: Element, now nowMicros: Int64) -> Bool {
        let target = clock.targetPresentTimeMicros(forPTSMicros: pts)
        if nowMicros.saturatingSubtracting(target) > lateBudgetMicros {
            droppedLate += 1
            return false
        }
        let index = insertionIndex(forPTS: pts)
        entries.insert(Entry(pts: pts, element: element), at: index)
        guard entries.count > capacity else { return true }
        entries.removeFirst()
        droppedOverflow += 1
        return index > 0  // index 0 means the incoming element was the oldest and just evicted itself
    }

    /// Removes and returns, in PTS order, every element whose target present time has arrived
    /// (`target <= nowMicros`). Due elements that have drifted more than ``lateBudgetMicros`` past
    /// their target by now are dropped and counted in ``droppedLate`` instead of returned.
    public mutating func popDue(now nowMicros: Int64) -> [Element] {
        var due: [Element] = []
        var dropIndex = 0
        // Sorted by PTS + monotonic mapping ⇒ sorted by target, so we can stop at the first not-due.
        while dropIndex < entries.count {
            let entry = entries[dropIndex]
            let target = clock.targetPresentTimeMicros(forPTSMicros: entry.pts)
            if target > nowMicros { break }
            if nowMicros.saturatingSubtracting(target) > lateBudgetMicros {
                droppedLate += 1
            } else {
                due.append(entry.element)
            }
            dropIndex += 1
        }
        entries.removeFirst(dropIndex)
        return due
    }

    /// First position whose PTS exceeds `pts` (upper bound), keeping equal-PTS insertion order stable.
    private func insertionIndex(forPTS pts: UInt64) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].pts <= pts { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

private extension Int64 {
    func saturatingAdding(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }

    func saturatingSubtracting(_ other: Int64) -> Int64 {
        let (difference, overflow) = subtractingReportingOverflow(other)
        return overflow ? (other > 0 ? .min : .max) : difference
    }
}
