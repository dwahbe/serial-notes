import SwiftUI

struct ManualNotesWindowView: View {
    @Environment(ManualNotesStore.self) private var notesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ManualNotesMarkdownEditor(text: Binding(
                get: { notesStore.text },
                set: { notesStore.updateText($0) }
            ), isEditable: notesStore.isEditable)

            if let error = notesStore.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !notesStore.isEditable {
                Text("Notes are locked after recording stops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(
            minWidth: ManualNotesWindowController.minSize.width,
            minHeight: ManualNotesWindowController.minSize.height
        )
    }
}
