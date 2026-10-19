import SwiftUI

/// How the app looks and speaks, as the General screen chose.
///
/// [LAW:single-enforcer] The settings window and the panel are the app's two SwiftUI roots, and this is
/// the one place the appearance and the language reach them.
private struct AppLook: ViewModifier {
    let look: AppAppearanceModel
    let language: AppLanguageModel

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(look.value.colorScheme)
            .environment(\.locale, language.value.locale)
    }
}

extension View {
    func appLook(_ look: AppAppearanceModel, _ language: AppLanguageModel) -> some View {
        modifier(AppLook(look: look, language: language))
    }
}
