import SwiftUI
import UniformTypeIdentifiers

/// A reference to a file on disk; nothing is copied.
struct ShelfItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] {
        didSet { Persistence.save(items, to: "shelf.json") }
    }

    init() {
        items = (Persistence.load([ShelfItem].self, from: "shelf.json") ?? []).filter(\.exists)
    }

    func add(_ urls: [URL]) {
        for url in urls where url.isFileURL && !items.contains(where: { $0.path == url.path }) {
            items.append(ShelfItem(path: url.path))
        }
    }

    func remove(_ item: ShelfItem) { items.removeAll { $0.id == item.id } }
    func clear() { items.removeAll() }
    func pruneMissing() { items.removeAll { !$0.exists } }
}

struct ShelfView: View {
    @EnvironmentObject var store: ShelfStore
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Shelf")
                    .font(.system(size: 13, weight: .bold))
                Text("\(store.items.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !store.items.isEmpty {
                    Text("Drag files out · double-click to open")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Clear") { store.clear() }
                        .buttonStyle(PillButtonStyle())
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: store.items.isEmpty ? [6, 5] : []))
                    .foregroundStyle(Color.white.opacity(isTargeted ? 0.6 : (store.items.isEmpty ? 0.22 : 0.08)))
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.white.opacity(isTargeted ? 0.08 : 0.03))
                    )

                if store.items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 26))
                        Text("Drop files here")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(isTargeted ? 0.9 : 0.45))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(store.items) { item in
                                ShelfItemView(item: item)
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                store.add(urls)
                return !urls.isEmpty
            } isTargeted: { isTargeted = $0 }
        }
        .onAppear { store.pruneMissing() }
    }
}

private struct ShelfItemView: View {
    @EnvironmentObject var store: ShelfStore
    let item: ShelfItem
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 52, height: 52)
            Text(item.name)
                .font(.system(size: 11))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(width: 84, height: 28, alignment: .top)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(hovering ? 0.1 : 0))
        )
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    store.remove(item)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .offset(x: 2, y: -2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
            Divider()
            Button("Remove from Shelf", role: .destructive) { store.remove(item) }
        }
        .help(item.path)
    }
}
