import Foundation

extension Alert.Position {
    /// The Alerts screen's wording for where the pill sits.
    var title: String {
        switch self {
        case .center: "Center of Screen"
        case .top: "Top of Screen"
        }
    }
}

extension Alert {
    /// The card's grey line: the position, then only the options that are on, joined by " • ".
    var summary: String {
        let options = [glow ? "Border Glow" : nil, sound ? "Sound" : nil].compactMap { $0 }
        return ([position.title] + options).joined(separator: " • ")
    }
}

extension AlertSettings {
    /// The alerts of one kind as their list shows them: lowest threshold first.
    func alerts(_ kind: Alert.Kind) -> [Alert] {
        alerts.filter { $0.kind == kind }.sorted { $0.threshold < $1.threshold }
    }

    /// A new alert starts at a level the reference list has no card for, at the top of the screen and heard.
    mutating func add(_ kind: Alert.Kind) {
        let threshold = switch kind { case .low: 10; case .charged: 90 }
        alerts.append(Alert(kind: kind, threshold: threshold, position: .top, glow: false, sound: true))
    }

    mutating func remove(_ id: Alert.ID) {
        alerts.removeAll { $0.id == id }
    }
}
