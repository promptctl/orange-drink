import Foundation

/// One notification as NotificationCenter's accessibility tree shows it.
struct NotificationValues: Equatable, Sendable {
    /// The alert macOS keeps up until it is closed. An app's is `AXNotificationCenterBanner` unless its user chose Alerts.
    static let alert = "AXNotificationCenterAlert"

    let subrole: String
    let title: String
    let body: String
    let description: String
    /// Every action the element names. Custom ones read `Name:Close` in the Mac's language.
    let actions: [String]
}

/// Which clause of the rule a notification failed, so the log can tell an alert macOS reshaped from another app's banner.
enum Refusal: String, CaseIterable, Sendable {
    case subrole, words, description, actions
}

/// What the rule says of one notification.
///
/// [LAW:parse-dont-validate] `close` carries the action, so the shape that makes it safe to press cannot come apart from
/// the press.
enum Verdict: Equatable, Sendable {
    case close(action: String)
    case refused(Refusal)
}

extension NotificationValues {
    /// Words alone would also catch an app that posts the same ones, so the subrole and the description have to agree.
    /// macOS 14 makes the description the title, and macOS 15 and 26 "title, body", joined in the Mac's language: "、" in
    /// Japanese, a space in Chinese, "،" and bidi marks in Arabic. So with the words taken out, nothing that could be a name
    /// may be left. An app's reads "Script Editor" or "Script Editor, Low Battery, ...", and a stack's ends ", stacked". An
    /// app displayed as "Low Battery" or in punctuation alone, set to Alerts, posting these exact words still passes:
    /// macOS 26 names no poster, and only that app is harmed.
    ///
    /// Its custom actions are Show Details and Close, so position is what's read. Any other shape could open the poster.
    func verdict(knowing words: Set<LowBatteryWords>) -> Verdict {
        guard subrole == Self.alert else { return .refused(.subrole) }
        guard words.contains(LowBatteryWords(title: title, body: body)) else { return .refused(.words) }
        let rest = description.replacingOccurrences(of: title, with: "").replacingOccurrences(of: body, with: "")
        guard description.contains(title), !rest.contains(where: { $0.isLetter || $0.isNumber || $0.isSymbol }) else { return .refused(.description) }
        let custom = actions.filter { $0.hasPrefix("Name:") }
        guard custom.count == 2 else { return .refused(.actions) }
        return .close(action: custom[1])
    }
}
