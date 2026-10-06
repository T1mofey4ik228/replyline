import Foundation
import SwiftUI

struct PromptProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var instructions: String

    static let starterProfiles = [
        PromptProfile(
            id: UUID(),
            name: "Підтримка клієнтів",
            instructions: """
            You help a customer support representative at a US household-goods moving company.
            Write one brief, natural, empathetic reply in clear spoken American English.
            Address only what the customer said. Do not claim that an action was completed,
            promise compensation, invent policy, or ask for sensitive payment information.
            If a detail is unknown, say you will check it. Return only the reply, without quotes.
            """
        ),
        PromptProfile(
            id: UUID(),
            name: "Загальні задачі",
            instructions: """
            You are a helpful assistant. Respond clearly and concisely to the transcribed message.
            Match the language and tone requested by the user. If the request is ambiguous, ask
            one short clarifying question. Do not invent facts. Return only the response text.
            """
        )
    ]
}

@MainActor
final class PromptProfileStore: ObservableObject {
    @Published private(set) var profiles: [PromptProfile]
    @Published private(set) var selectedProfileID: UUID

    private let defaultsKey = "replyline.promptProfiles.v1"
    private let selectedIDKey = "replyline.selectedPromptProfile.v1"

    init() {
        let loadedProfiles: [PromptProfile]
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([PromptProfile].self, from: data),
           !saved.isEmpty {
            loadedProfiles = saved
        } else {
            loadedProfiles = PromptProfile.starterProfiles
        }
        profiles = loadedProfiles

        let initialSelectedID: UUID
        if let savedID = UserDefaults.standard.string(forKey: selectedIDKey),
           let uuid = UUID(uuidString: savedID),
           loadedProfiles.contains(where: { $0.id == uuid }) {
            initialSelectedID = uuid
        } else {
            initialSelectedID = loadedProfiles[0].id
        }
        selectedProfileID = initialSelectedID
        persist()
    }

    var selectedProfile: PromptProfile {
        profiles.first(where: { $0.id == selectedProfileID }) ?? profiles[0]
    }

    func select(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        persist()
    }

    @discardableResult
    func addProfile() -> PromptProfile {
        let profile = PromptProfile(
            id: UUID(),
            name: "Новий профіль",
            instructions: "Describe the role, tone, language, goals, and rules for this task."
        )
        profiles.append(profile)
        selectedProfileID = profile.id
        persist()
        return profile
    }

    func update(_ profile: PromptProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        persist()
    }

    func delete(_ id: UUID) {
        guard profiles.count > 1,
              let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: index)
        if selectedProfileID == id { selectedProfileID = profiles[min(index, profiles.count - 1)].id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        UserDefaults.standard.set(selectedProfileID.uuidString, forKey: selectedIDKey)
    }
}
