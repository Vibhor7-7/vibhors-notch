import SwiftUI

struct TaskItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var isDone = false
    var created = Date()
    var completedAt: Date?
}

final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [TaskItem] {
        didSet { Persistence.save(tasks, to: "tasks.json") }
    }

    init() {
        tasks = Persistence.load([TaskItem].self, from: "tasks.json") ?? []
    }

    var openTasks: [TaskItem] { tasks.filter { !$0.isDone }.sorted { $0.created < $1.created } }
    var doneTasks: [TaskItem] {
        tasks.filter(\.isDone).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    func add(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tasks.append(TaskItem(title: trimmed))
    }

    func toggle(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].isDone.toggle()
        tasks[i].completedAt = tasks[i].isDone ? Date() : nil
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete(id) }
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].title = trimmed
    }

    func delete(_ id: UUID) { tasks.removeAll { $0.id == id } }
    func clearCompleted() { tasks.removeAll(where: \.isDone) }
}

struct TasksView: View {
    @EnvironmentObject var store: TaskStore
    @State private var newTitle = ""
    @State private var showCompleted = true
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tasks")
                    .font(.system(size: 13, weight: .bold))
                Text("\(store.openTasks.count) left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !store.doneTasks.isEmpty {
                    Button("Clear Completed") {
                        withAnimation(.easeInOut(duration: 0.2)) { store.clearCompleted() }
                    }
                    .buttonStyle(PillButtonStyle())
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.4))
                TextField("Add a task and press Return", text: $newTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($inputFocused)
                    .onSubmit {
                        withAnimation(.easeInOut(duration: 0.2)) { store.add(newTitle) }
                        newTitle = ""
                        inputFocused = true
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.07)))
            .onTapGesture { inputFocused = true }

            if store.tasks.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.system(size: 24))
                    Text("No tasks yet")
                        .font(.system(size: 13))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(store.openTasks) { TaskRow(task: $0) }

                        if !store.doneTasks.isEmpty {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { showCompleted.toggle() }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .bold))
                                        .rotationEffect(.degrees(showCompleted ? 90 : 0))
                                    Text("Completed \(store.doneTasks.count)")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.top, 8)
                                .padding(.bottom, 2)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if showCompleted {
                                ForEach(store.doneTasks) { TaskRow(task: $0) }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct TaskRow: View {
    @EnvironmentObject var store: TaskStore
    let task: TaskItem

    @State private var hovering = false
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 9) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { store.toggle(task.id) }
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(task.isDone ? Color.green : Color.white.opacity(0.55))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onChange(of: fieldFocused) { _, focused in if !focused { commit() } }
            } else {
                Text(task.title)
                    .font(.system(size: 13))
                    .strikethrough(task.isDone, color: .white.opacity(0.4))
                    .foregroundStyle(task.isDone ? Color.white.opacity(0.4) : Color.white)
                    .lineLimit(2)
                    .onTapGesture(count: 2) {
                        draft = task.title
                        isEditing = true
                        fieldFocused = true
                    }
            }

            Spacer(minLength: 0)

            if hovering && !isEditing {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { store.delete(task.id) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Delete task")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(task.isDone ? "Mark as Not Done" : "Mark as Done") { store.toggle(task.id) }
            Button("Rename") {
                draft = task.title
                isEditing = true
                fieldFocused = true
            }
            Divider()
            Button("Delete", role: .destructive) { store.delete(task.id) }
        }
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false
        store.rename(task.id, to: draft)
    }
}
