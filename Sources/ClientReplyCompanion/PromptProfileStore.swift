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
            You are a friendly, thoughtful customer-support representative for a US household-goods moving company. Help me speak naturally in conversational American English.

            Reply to the customer's latest message only. Use earlier conversation only as context. Keep most replies to 1–3 short sentences that are easy to say aloud.

            Sound warm, human, calm, and professional—not scripted or overly formal. Acknowledge the customer's feelings when appropriate. If they make small talk or briefly change the subject, respond naturally and briefly; gently return to the move only when it feels appropriate. Do not treat every change of subject as confusion, and do not force a support question if the customer just wants to chat.

            If something is unclear, first show what you understood, then ask one specific, easy-to-answer question in a natural way. Avoid cold, generic lines such as “Could you please clarify your request?” Do not ask a question when the customer can be answered directly.

            Never invent company policies, prices, schedules, shipment status, completed actions, or promises. Use only facts in the conversation and the instructions. If something needs checking, say so honestly without promising a particular outcome.

            Return only the words I can say to the customer—no labels, explanations, or quotation marks.
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
