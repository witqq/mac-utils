/// One entry of a display's mode catalog, reduced to the facts the selection rule needs.
struct DisplayModeCandidate: Equatable, Sendable {
    /// Position in the catalog as reported by the system; used as the deterministic tie-break.
    let index: Int
    let pixelCount: Int
    let isDefault: Bool
    let isNative: Bool
    let isCurrent: Bool
}

/// Chooses the mode a display should return to after it leaves mirroring.
///
/// While two displays mirror each other, macOS runs both in a mode the pair can share, which is
/// usually the source display's mode. After un-mirroring, the other display keeps that shared mode
/// until something selects its own mode again. The rule prefers the mode the panel marks as its
/// default, then its native mode. When the best candidate is already current, or when the catalog
/// offers neither flag, nothing is selected and the display keeps its current mode.
enum DisplayModeSelection {
    static func preferredCandidateIndex(in candidates: [DisplayModeCandidate]) -> Int? {
        let chosen = best(candidates.filter(\.isDefault)) ?? best(candidates.filter(\.isNative))
        guard let chosen, !chosen.isCurrent else { return nil }
        return chosen.index
    }

    private static func best(_ candidates: [DisplayModeCandidate]) -> DisplayModeCandidate? {
        candidates.min { lhs, rhs in
            if lhs.pixelCount != rhs.pixelCount { return lhs.pixelCount > rhs.pixelCount }
            return lhs.index < rhs.index
        }
    }
}
