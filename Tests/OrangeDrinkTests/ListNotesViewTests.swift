import AppKit
import SwiftUI
import Testing
@testable import OrangeDrink

// [LAW:verifiable-goals] A fully read list draws exactly what it drew before the notes view existed: the view with nothing
// to say takes no space, not even the spacing its parent stack puts between children.
@MainActor struct ListNotesViewTests {
    private static func height(of content: some View) -> CGFloat {
        NSHostingView(rootView: content.frame(width: 300)).fittingSize.height
    }

    @Test func aViewWithNothingToSayAddsNoSpacingToItsStack() {
        let bare = Self.height(of: VStack(alignment: .leading, spacing: 8) { Text("card"); Text("caption") })
        let withNotes = Self.height(of: VStack(alignment: .leading, spacing: 8) {
            Text("card"); Text("caption")
            ListNotesView(rowsAreEmpty: false, notes: ListNotes(empty: nil, unread: []))
        })
        #expect(withNotes == bare)
    }
}
