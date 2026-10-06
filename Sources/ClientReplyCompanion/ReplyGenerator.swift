import Foundation
import FoundationModels

struct ReplyGenerator {
    func streamReply(
        for customerMessage: String,
        context: String = "",
        instructions: String,
        provider: AIProvider = .apple,
        onUpdate: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let replyInstructions = instructions + "\n\nRespond only to the latest customer message. Any previous conversation is context only; do not answer it again. If there is no new request in the latest message, ask one short clarifying question."
        let replyInput = context.isEmpty
            ? "Latest customer message:\n\(customerMessage)"
            : "Previous conversation (context only; do not reply to it):\n\(context)\n\nLatest customer message (reply only to this):\n\(customerMessage)"
        if provider == .chatGPT {
            return try await ChatGPTPlanClient.shared.streamText(
                instructions: replyInstructions,
                input: replyInput,
                onUpdate: onUpdate
            )
        }
        try ensureModelAvailable()

        let session = LanguageModelSession(instructions: replyInstructions)
        let responseStream = session.streamResponse(to: replyInput)
        var latestText = ""
        for try await snapshot in responseStream {
            latestText = snapshot.content
            await onUpdate(latestText)
        }
        return latestText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func streamSummary(
        for transcript: String,
        provider: AIProvider = .apple,
        onUpdate: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        if provider == .chatGPT {
            return try await ChatGPTPlanClient.shared.streamText(
                instructions: """
                Ти помічник служби підтримки. За транскрипцією англомовної розмови підготуй стислий конспект українською.
                Використовуй лише факти з транскрипції, нічого не вигадуй. Якщо даних бракує — прямо познач це.
                Структура:
                1. Проблема клієнта
                2. Важливі деталі
                3. Що клієнт просить або очікує
                4. Наступні кроки / що ще треба з’ясувати
                Якщо якийсь пункт відсутній у розмові, не заповнюй його припущеннями.
                """,
                input: transcript,
                onUpdate: onUpdate
            )
        }
        try ensureModelAvailable()

        let session = LanguageModelSession(instructions: """
        Ти помічник служби підтримки. За транскрипцією англомовної розмови підготуй стислий конспект українською.
        Використовуй лише факти з транскрипції, нічого не вигадуй. Якщо даних бракує — прямо познач це.
        Структура:
        1. Проблема клієнта
        2. Важливі деталі
        3. Що клієнт просить або очікує
        4. Наступні кроки / що ще треба з’ясувати
        Якщо якийсь пункт відсутній у розмові, не заповнюй його припущеннями.
        """)
        let responseStream = session.streamResponse(to: transcript)
        var latestText = ""
        for try await snapshot in responseStream {
            latestText = snapshot.content
            await onUpdate(latestText)
        }
        return latestText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensureModelAvailable() throws {
        if case .unavailable(let reason) = SystemLanguageModel.default.availability {
            throw ReplyError.modelUnavailable(reason)
        }
    }

    enum ReplyError: LocalizedError {
        case modelUnavailable(SystemLanguageModel.Availability.UnavailableReason)

        var errorDescription: String? {
            switch self {
            case .modelUnavailable(.deviceNotEligible):
                "Цей Mac не підтримує локальну модель Apple Intelligence. Для безкоштовної генерації потрібен інший локальний AI-рушій."
            case .modelUnavailable(.appleIntelligenceNotEnabled):
                "Apple Intelligence недоступна. У System Settings → General → Language & Region і Apple Intelligence & Siri задай для Mac та Siri одну й ту саму підтримувану мову (наприклад, English (US)), увімкни Apple Intelligence і зачекай на завантаження моделі."
            case .modelUnavailable(.modelNotReady):
                "Модель Apple Intelligence ще не готова. Зачекай, поки macOS завантажить її, і спробуй знову."
            case .modelUnavailable:
                "Apple Intelligence тимчасово недоступна. Перевір налаштування Apple Intelligence & Siri і спробуй знову."
            }
        }
    }
}
