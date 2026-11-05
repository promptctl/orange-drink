import OSLog

extension Logger {
    /// Runs a history read, and logs its failure before passing it on to the screen that asked.
    ///
    /// [LAW:single-enforcer] The history that owns the read logs its failure; the screens only show it.
    func loggingFailure<Value>(of what: String, _ body: () throws -> Value) throws -> Value {
        do { return try body() } catch {
            self.error("\(what, privacy: .public) unreadable: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}
