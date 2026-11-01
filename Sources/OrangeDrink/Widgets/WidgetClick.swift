import Foundation
import WidgetKit

/// A click on a placed widget. With no `widgetURL` or `Link` in the widget, macOS opens the app and passes it a user
/// activity, and it does so for an app with no window of its own (orange-widgets-5jo.gq2 measured it on a real click).
struct WidgetClick: Equatable {
    let kind: WidgetKind

    /// [LAW:parse-dont-validate] The kind is `userInfo`'s and never `activityType`'s, which for a configurable widget
    /// is its intent's name.
    init?(_ activity: NSUserActivity) {
        guard let kind = (activity.userInfo?[WidgetCenter.UserInfoKey.kind] as? String).flatMap(WidgetKind.init(rawValue:)) else { return nil }
        self.kind = kind
    }

    /// [LAW:effects-at-boundaries] The log line, a pure function of the click. scripts/widget-click-check reads it.
    ///
    /// The mouse-down outside the panel closes it, and the activity follows the mouse-up, so a repeat click normally
    /// finds it closed. macOS promises no such order, so the line says which it was.
    func line(panelWasOpen: Bool) -> String {
        "widget click by user activity: \(kind.rawValue), panel was \(panelWasOpen ? "open" : "closed")"
    }
}
