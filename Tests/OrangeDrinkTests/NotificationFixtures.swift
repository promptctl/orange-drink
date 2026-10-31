@testable import OrangeDrink

// What NotificationCenter's accessibility tree showed on macOS 26.6.2, 15.7.7, and 14.8.7, in English, French, Japanese,
// Simplified Chinese, Arabic, Brazilian Portuguese, and Polish, from spikes/orange-distribution-kg2.o9e/output.txt.
// ControlCenter's own code posted the low battery alerts, and Script Editor the others. Bidi marks are written as escapes.
enum NotificationFixtures {
    static let lowBatteryAlerts = [
        // macOS 15, 26
        NotificationValues(subrole: "AXNotificationCenterAlert", title: "Low Battery", body: "Your Mac will sleep soon unless plugged into a power outlet.",
                           description: "Low Battery, Your Mac will sleep soon unless plugged into a power outlet.",
                           actions: ["AXPress", "Name:Show Details", "Name:Close"]),
        // macOS 15, 26
        NotificationValues(subrole: "AXNotificationCenterAlert", title: "Batterie faible", body: "Branchez le Mac sur secteur pour ne pas suspendre l’activité.",
                           description: "Batterie faible, Branchez le Mac sur secteur pour ne pas suspendre l’activité.",
                           actions: ["AXPress", "Name:Afficher les détails", "Name:Fermer"]),
        // macOS 15, 26
        NotificationValues(subrole: "AXNotificationCenterAlert", title: "バッテリー残量低下", body: "電源コンセントに接続しなければ、このMacは間もなくスリープ状態に入ります。",
                           description: "バッテリー残量低下、電源コンセントに接続しなければ、このMacは間もなくスリープ状態に入ります。",
                           actions: ["AXPress", "Name:詳細を表示", "Name:閉じる"]),
        // macOS 15, 26
        NotificationValues(subrole: "AXNotificationCenterAlert", title: "电池电量不足", body: "请插入电源插座，否则Mac将很快进入睡眠。",
                           description: "电池电量不足 请插入电源插座，否则Mac将很快进入睡眠。",
                           actions: ["AXPress", "Name:显示详细信息", "Name:关闭"]),
        // macOS 15, 26
        NotificationValues(subrole: "AXNotificationCenterAlert", title: "شحن البطارية منخفض", body: "سيتم إسبات الـ Mac قريبًا إذا لم تقم بتوصيله بمنفذ طاقة.",
                           description: "\u{200F}\u{2068}شحن البطارية منخفض\u{2069}، \u{2068}سيتم إسبات الـ Mac قريبًا إذا لم تقم بتوصيله بمنفذ طاقة.\u{2069}",
                           actions: ["AXPress", "Name:إظهار التفاصيل", "Name:إغلاق"]),
        // macOS 15, 26
        NotificationValues(subrole: "AXNotificationCenterAlert", title: "Pouca Bateria", body: "O Mac entrará em repouso em breve se não for conectado a uma tomada.",
                           description: "Pouca Bateria, O Mac entrará em repouso em breve se não for conectado a uma tomada.",
                           actions: ["AXPress", "Name:Mostrar Detalhes", "Name:Fechar"]),
        // macOS 15, 26
        NotificationValues(subrole: "AXNotificationCenterAlert", title: "Niski poziom baterii", body: "Jeśli nie podłączysz Maca do zasilania, zostanie uśpiony.",
                           description: "Niski poziom baterii, Jeśli nie podłączysz Maca do zasilania, zostanie uśpiony.",
                           actions: ["AXPress", "Name:Pokaż szczegóły", "Name:Zamknij"]),
        // macOS 14
        NotificationValues(subrole: "AXNotificationCenterAlert", title: "Low Battery", body: "Your Mac will sleep soon unless plugged into a power outlet.",
                           description: "Low Battery",
                           actions: ["AXScrollToVisible", "AXPress", "Name:Show Details", "Name:Close"]),
        // macOS 14
        NotificationValues(subrole: "AXNotificationCenterAlert", title: "Batterie faible", body: "Branchez le Mac sur secteur pour ne pas suspendre l’activité.",
                           description: "Batterie faible",
                           actions: ["AXScrollToVisible", "AXPress", "Name:Afficher les détails", "Name:Fermer"]),
        // macOS 14
        NotificationValues(subrole: "AXNotificationCenterAlert", title: "バッテリー残量低下", body: "電源コンセントに接続しなければ、このMacは間もなくスリープ状態に入ります。",
                           description: "バッテリー残量低下",
                           actions: ["AXScrollToVisible", "AXPress", "Name:詳細を表示", "Name:閉じる"]),
        // macOS 14
        NotificationValues(subrole: "AXNotificationCenterAlert", title: "电池电量不足", body: "请插入电源插座，否则Mac将很快进入睡眠。",
                           description: "电池电量不足",
                           actions: ["AXScrollToVisible", "AXPress", "Name:显示详细信息", "Name:关闭"]),
        // macOS 14
        NotificationValues(subrole: "AXNotificationCenterAlert", title: "شحن البطارية منخفض", body: "سيتم إسبات الـ Mac قريبًا إذا لم تقم بتوصيله بمنفذ طاقة.",
                           description: "شحن البطارية منخفض",
                           actions: ["AXScrollToVisible", "AXPress", "Name:إظهار التفاصيل", "Name:إغلاق"]),
        // macOS 14
        NotificationValues(subrole: "AXNotificationCenterAlert", title: "Pouca Bateria", body: "O Mac entrará em repouso em breve se não for conectado a uma tomada.",
                           description: "Pouca Bateria",
                           actions: ["AXScrollToVisible", "AXPress", "Name:Mostrar Detalhes", "Name:Fechar"]),
        // macOS 14
        NotificationValues(subrole: "AXNotificationCenterAlert", title: "Niski poziom baterii", body: "Jeśli nie podłączysz Maca do zasilania, zostanie uśpiony.",
                           description: "Niski poziom baterii",
                           actions: ["AXScrollToVisible", "AXPress", "Name:Pokaż szczegóły", "Name:Zamknij"]),
    ]

    static let otherApps = [
        // macOS 15, 26
        NotificationValues(subrole: "AXNotificationCenterBanner", title: "First", body: "A banner",
                           description: "Script Editor, First, A banner",
                           actions: ["AXPress", "Name:Show Details", "Name:Show", "Name:Close"]),
        // macOS 15, 26
        NotificationValues(subrole: "AXNotificationCenterBanner", title: "Low Battery", body: "Your Mac will sleep soon unless plugged into a power outlet.",
                           description: "Script Editor, Low Battery, Your Mac will sleep soon unless plugged into a power outlet.",
                           actions: ["AXPress", "Name:Show Details", "Name:Show", "Name:Close"]),
        // macOS 15, 26
        NotificationValues(subrole: "AXNotificationCenterBannerStack", title: "Low Battery", body: "Your Mac will sleep soon unless plugged into a power outlet.",
                           description: "Script Editor, Low Battery, Your Mac will sleep soon unless plugged into a power outlet., stacked",
                           actions: ["AXPress", "Name:Show Details", "Name:Show", "Name:Clear All"]),
        // macOS 15, 26
        NotificationValues(subrole: "AXNotificationCenterBanner", title: "Batterie faible", body: "Branchez le Mac sur secteur pour ne pas suspendre l’activité.",
                           description: "Éditeur de script, Batterie faible, Branchez le Mac sur secteur pour ne pas suspendre l’activité.",
                           actions: ["AXPress", "Name:Afficher les détails", "Name:Afficher", "Name:Fermer"]),
        // macOS 15, 26
        NotificationValues(subrole: "AXNotificationCenterBanner", title: "バッテリー残量低下", body: "電源コンセントに接続しなければ、このMacは間もなくスリープ状態に入ります。",
                           description: "スクリプトエディタ、バッテリー残量低下, 電源コンセントに接続しなければ、このMacは間もなくスリープ状態に入ります。",
                           actions: ["AXPress", "Name:詳細を表示", "Name:表示", "Name:閉じる"]),
        // macOS 15, 26
        NotificationValues(subrole: "AXNotificationCenterBanner", title: "电池电量不足", body: "请插入电源插座，否则Mac将很快进入睡眠。",
                           description: "脚本编辑器 电池电量不足, 请插入电源插座，否则Mac将很快进入睡眠。",
                           actions: ["AXPress", "Name:显示详细信息", "Name:显示", "Name:关闭"]),
        // macOS 15, 26
        NotificationValues(subrole: "AXNotificationCenterBanner", title: "شحن البطارية منخفض", body: "سيتم إسبات الـ Mac قريبًا إذا لم تقم بتوصيله بمنفذ طاقة.",
                           description: "\u{200F}\u{2068}محرر البرامج النصية\u{2069}، \u{2068}شحن البطارية منخفض, سيتم إسبات الـ Mac قريبًا إذا لم تقم بتوصيله بمنفذ طاقة.\u{2069}",
                           actions: ["AXPress", "Name:إظهار التفاصيل", "Name:إظهار", "Name:إغلاق"]),
        // macOS 15, 26
        NotificationValues(subrole: "AXNotificationCenterBanner", title: "Pouca Bateria", body: "O Mac entrará em repouso em breve se não for conectado a uma tomada.",
                           description: "Editor de Scripts, Pouca Bateria, O Mac entrará em repouso em breve se não for conectado a uma tomada.",
                           actions: ["AXPress", "Name:Mostrar Detalhes", "Name:Mostrar", "Name:Fechar"]),
        // macOS 15, 26
        NotificationValues(subrole: "AXNotificationCenterBanner", title: "Niski poziom baterii", body: "Jeśli nie podłączysz Maca do zasilania, zostanie uśpiony.",
                           description: "Edytor skryptów, Niski poziom baterii, Jeśli nie podłączysz Maca do zasilania, zostanie uśpiony.",
                           actions: ["AXPress", "Name:Pokaż szczegóły", "Name:Pokaż", "Name:Zamknij"]),
        // macOS 14
        NotificationValues(subrole: "AXNotificationCenterBanner", title: "First", body: "A banner",
                           description: "Script Editor",
                           actions: ["AXScrollToVisible", "AXPress", "Name:Show Details", "Name:Show", "Name:Close"]),
        // macOS 14
        NotificationValues(subrole: "AXNotificationCenterBanner", title: "Low Battery", body: "Your Mac will sleep soon unless plugged into a power outlet.",
                           description: "Script Editor",
                           actions: ["AXScrollToVisible", "AXPress", "Name:Show Details", "Name:Show", "Name:Close"]),
        // macOS 14
        NotificationValues(subrole: "AXNotificationCenterBannerStack", title: "Low Battery", body: "Your Mac will sleep soon unless plugged into a power outlet.",
                           description: "Script Editor, stacked",
                           actions: ["AXScrollToVisible", "AXPress", "Name:Show Details", "Name:Show", "Name:Clear All"]),
        // macOS 14
        NotificationValues(subrole: "AXNotificationCenterBanner", title: "Batterie faible", body: "Branchez le Mac sur secteur pour ne pas suspendre l’activité.",
                           description: "Éditeur de script",
                           actions: ["AXScrollToVisible", "AXPress", "Name:Afficher les détails", "Name:Afficher", "Name:Fermer"]),
        // macOS 14
        NotificationValues(subrole: "AXNotificationCenterBanner", title: "バッテリー残量低下", body: "電源コンセントに接続しなければ、このMacは間もなくスリープ状態に入ります。",
                           description: "スクリプトエディタ",
                           actions: ["AXScrollToVisible", "AXPress", "Name:詳細を表示", "Name:表示", "Name:閉じる"]),
        // macOS 14
        NotificationValues(subrole: "AXNotificationCenterBanner", title: "电池电量不足", body: "请插入电源插座，否则Mac将很快进入睡眠。",
                           description: "脚本编辑器",
                           actions: ["AXScrollToVisible", "AXPress", "Name:显示详细信息", "Name:显示", "Name:关闭"]),
        // macOS 14
        NotificationValues(subrole: "AXNotificationCenterBanner", title: "شحن البطارية منخفض", body: "سيتم إسبات الـ Mac قريبًا إذا لم تقم بتوصيله بمنفذ طاقة.",
                           description: "محرر البرامج النصية",
                           actions: ["AXScrollToVisible", "AXPress", "Name:إظهار التفاصيل", "Name:إظهار", "Name:إغلاق"]),
        // macOS 14
        NotificationValues(subrole: "AXNotificationCenterBanner", title: "Pouca Bateria", body: "O Mac entrará em repouso em breve se não for conectado a uma tomada.",
                           description: "Editor de Scripts",
                           actions: ["AXScrollToVisible", "AXPress", "Name:Mostrar Detalhes", "Name:Mostrar", "Name:Fechar"]),
        // macOS 14
        NotificationValues(subrole: "AXNotificationCenterBanner", title: "Niski poziom baterii", body: "Jeśli nie podłączysz Maca do zasilania, zostanie uśpiony.",
                           description: "Edytor skryptów",
                           actions: ["AXScrollToVisible", "AXPress", "Name:Pokaż szczegóły", "Name:Pokaż", "Name:Zamknij"]),
    ]

    static let alert = lowBatteryAlerts[0]
    static let banner = otherApps.first { $0.title == alert.title && $0.subrole == "AXNotificationCenterBanner" }!

    /// The words those alerts show, as the tables give them on each macOS.
    static let words = Set(lowBatteryAlerts.map { LowBatteryWords(title: $0.title, body: $0.body) })
}
