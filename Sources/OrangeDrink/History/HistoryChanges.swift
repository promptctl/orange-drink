import Observation

/// Counts the writes that reached the history store, whoever made them, so a screen showing any of the
/// history reloads when the count moves and not on a schedule of its own.
///
/// [LAW:single-enforcer] The one reload signal: every recorder bumps it after its write succeeds.
@Observable @MainActor final class HistoryChanges {
    private(set) var revision = 0

    func wrote() { revision += 1 }
}
