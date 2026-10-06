import Foundation
import SwiftUI

enum AIProvider: String, CaseIterable, Identifiable {
    case chatGPT
    case apple

    var id: String { rawValue }
    var title: String { self == .chatGPT ? "GPT через ChatGPT" : "Apple Intelligence на Mac" }
    var detail: String {
        self == .chatGPT
            ? "Текст запиту надсилається OpenAI; використання списується з плану ChatGPT"
            : "Обробка на цьому Mac; без використання плану ChatGPT"
    }
}

@MainActor
final class AIProviderStore: ObservableObject {
    static let shared = AIProviderStore()
    @Published var selected: AIProvider {
        didSet { UserDefaults.standard.set(selected.rawValue, forKey: "replyline.aiProvider.v1") }
    }

    private init() {
        selected = AIProvider(rawValue: UserDefaults.standard.string(forKey: "replyline.aiProvider.v1") ?? "chatGPT") ?? .chatGPT
    }
}
