import SwiftUI

struct PromptProfilesView: View {
    @EnvironmentObject private var store: PromptProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?

    private var selectedProfile: PromptProfile? {
        store.profiles.first(where: { $0.id == selectedID })
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Профілі промтів")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("Обери стиль для поточної задачі")
                    .font(.system(size: 12)).foregroundStyle(.secondary)

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(store.profiles) { profile in
                            Button {
                                selectedID = profile.id
                                store.select(profile.id)
                            } label: {
                                HStack {
                                    Text(profile.name.isEmpty ? "Без назви" : profile.name)
                                        .lineLimit(2)
                                    Spacer(minLength: 0)
                                    if profile.id == store.selectedProfileID {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .bold))
                                    }
                                }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(profile.id == selectedID ? Color.teal : Color.primary)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(profile.id == selectedID ? Color.teal.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button {
                    let profile = store.addProfile()
                    selectedID = profile.id
                } label: {
                    Label("Новий профіль", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .frame(width: 220)

            Divider()

            if let profile = selectedProfile {
                editor(for: profile)
            } else {
                ContentUnavailableView("Обери профіль", systemImage: "text.book.closed")
            }
        }
        .frame(minWidth: 700, minHeight: 520)
        .onAppear { selectedID = store.selectedProfileID }
    }

    private func editor(for profile: PromptProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Налаштування профілю")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Опиши роль, тон спілкування, мову відповіді та правила.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text("Назва")
                .font(.system(size: 12, weight: .semibold))
            TextField("Наприклад: Ввічлива підтримка", text: binding(for: profile, keyPath: \.name))
                .textFieldStyle(.roundedBorder)

            HStack(alignment: .firstTextBaseline) {
                Text("Власний промт")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Зміни зберігаються автоматично")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            TextEditor(text: binding(for: profile, keyPath: \.instructions))
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1), lineWidth: 1))

            HStack {
                Button(role: .destructive) {
                    store.delete(profile.id)
                    selectedID = store.selectedProfileID
                } label: {
                    Label("Видалити профіль", systemImage: "trash")
                        .font(.system(size: 12))
                }
                .disabled(store.profiles.count <= 1)
                Spacer()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func binding(for profile: PromptProfile, keyPath: WritableKeyPath<PromptProfile, String>) -> Binding<String> {
        Binding(
            get: { store.profiles.first(where: { $0.id == profile.id })?[keyPath: keyPath] ?? "" },
            set: { value in
                guard var updated = store.profiles.first(where: { $0.id == profile.id }) else { return }
                updated[keyPath: keyPath] = value
                store.update(updated)
            }
        )
    }
}
