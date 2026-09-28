import SwiftUI

struct Note: Identifiable, Codable, Equatable {
    var id = UUID()
    var text = ""
    var updated = Date()

    var title: String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first
        let trimmed = first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return trimmed.isEmpty ? "New Note" : trimmed
    }

    var preview: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.dropFirst().first.map(String.init) ?? ""
    }
}

final class NotesStore: ObservableObject {
    @Published private(set) var notes: [Note] {
        didSet { Persistence.save(notes, to: "notes.json") }
    }
    @Published var selectedID: UUID?

    init() {
        notes = Persistence.load([Note].self, from: "notes.json") ?? []
        selectedID = sortedNotes.first?.id
    }

    var sortedNotes: [Note] { notes.sorted { $0.updated > $1.updated } }

    @discardableResult
    func add() -> UUID {
        let note = Note()
        notes.append(note)
        selectedID = note.id
        return note.id
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        if selectedID == id { selectedID = sortedNotes.first?.id }
    }

    func text(for id: UUID) -> Binding<String> {
        Binding(
            get: { self.notes.first { $0.id == id }?.text ?? "" },
            set: { newValue in
                guard let i = self.notes.firstIndex(where: { $0.id == id }), self.notes[i].text != newValue else { return }
                self.notes[i].text = newValue
                self.notes[i].updated = Date()
            }
        )
    }

    func note(_ id: UUID?) -> Note? {
        notes.first { $0.id == id }
    }
}

struct NotesView: View {
    @EnvironmentObject var store: NotesStore
    @FocusState private var editorFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 180)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)
                .padding(.horizontal, 14)

            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notes")
                    .font(.system(size: 13, weight: .bold))
                Text("\(store.notes.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.add()
                    editorFocused = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(IconButtonStyle())
                .help("New note")
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(store.sortedNotes) { note in
                        NoteRow(note: note, isSelected: note.id == store.selectedID)
                            .onTapGesture { store.selectedID = note.id }
                            .contextMenu {
                                Button("Delete", role: .destructive) { store.delete(note.id) }
                            }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let id = store.selectedID, let note = store.note(id) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    if note.text.isEmpty {
                        Text("Start typing…")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: store.text(for: id))
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .focused($editorFocused)
                }
                HStack {
                    Text("Edited \(note.updated.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(note.text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .help("Copy note")
                    Button {
                        store.delete(id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .help("Delete note")
                }
            }
            .id(id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "note.text")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
                Text("No note selected")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Button("New Note") {
                    store.add()
                    editorFocused = true
                }
                .buttonStyle(PillButtonStyle(prominent: true))
            }
        }
    }
}

private struct NoteRow: View {
    let note: Note
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
            Text(note.preview.isEmpty ? note.updated.formatted(date: .abbreviated, time: .shortened) : note.preview)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(isSelected ? 0.14 : 0))
        )
        .contentShape(Rectangle())
    }
}
