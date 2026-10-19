import Foundation

extension Alert.Position {
    /// The Alerts screen's wording for where the pill sits.
    var title: Phrase {
        switch self {
        case .center: "Center of Screen"
        case .top: "Top of Screen"
        }
    }
}

extension Alert {
    /// The card's grey line: the position, then only the options that are on, joined by " • ".
    var summary: Phrase {
        let options: [Phrase] = [glow ? "Border Glow" : nil, sound ? "Sound" : nil].compactMap { $0 }
        return options.reduce(position.title) { "\($0) • \($1)" }
    }

    /// What the card's gear and trash buttons are called to a screen reader.
    func buttonName(_ action: Action) -> Phrase {
        switch (kind, action) {
        case (.low, .edit): "Edit low battery alert at \(threshold)%"
        case (.charged, .edit): "Edit charged alert at \(threshold)%"
        case (.low, .delete): "Delete low battery alert at \(threshold)%"
        case (.charged, .delete): "Delete charged alert at \(threshold)%"
        }
    }

    enum Action { case edit, delete }
}

extension Alert.Kind {
    /// The SF Symbol of this kind's battery, on its section header and on each of its cards.
    var symbol: String {
        switch self {
        case .low: "battery.25percent"
        case .charged: "battery.100percent.bolt"
        }
    }
}

extension AlertSettings {
    /// The alerts of one kind as their list shows them: lowest threshold first, equal ones in a fixed order.
    func alerts(_ kind: Alert.Kind) -> [Alert] {
        alerts.filter { $0.kind == kind }.sorted { ($0.threshold, $0.id.uuidString) < ($1.threshold, $1.id.uuidString) }
    }

    /// A new alert starts at a fixed level, at the top of the screen and heard; the user sets it from there.
    mutating func add(_ kind: Alert.Kind) {
        let threshold = switch kind { case .low: 10; case .charged: 90 }
        alerts.append(Alert(kind: kind, threshold: threshold, position: .top, glow: false, sound: true))
    }

    /// Applies one change to the alert with this id as it stands now. Changes are per field, so two
    /// edits in a row never write one another's field back; an alert removed meanwhile has nothing
    /// left to edit.
    mutating func edit(_ id: Alert.ID, _ change: (inout Alert) -> Void) {
        guard let index = alerts.firstIndex(where: { $0.id == id }) else { return }
        change(&alerts[index])
    }

    mutating func remove(_ id: Alert.ID) {
        alerts.removeAll { $0.id == id }
    }
}
