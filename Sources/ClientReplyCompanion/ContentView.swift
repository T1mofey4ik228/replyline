import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var capture: CaptureManager
    @EnvironmentObject private var promptProfiles: PromptProfileStore
    @StateObject private var aiProvider = AIProviderStore.shared
    @StateObject private var chatGPT = ChatGPTPlanClient.shared
    @State private var copied = false
    @State private var showingPromptProfiles = false

    private let ink = Color(red: 0.10, green: 0.16, blue: 0.22)
    private let muted = Color(red: 0.42, green: 0.49, blue: 0.55)
    private let teal = Color(red: 0.08, green: 0.55, blue: 0.48)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    promptProfilePicker
                    aiProviderPicker
                    sourcePicker
                    captureControls
                    transcriptCard
                    replyCard
                    if !capture.transcript.isEmpty { summaryCard }
                }
                .padding(32)
                .frame(maxWidth: 760, alignment: .leading)
            }
            .background(Color(red: 0.97, green: 0.98, blue: 0.98))
        }
        .foregroundStyle(ink)
        .alert("Потрібен дозвіл", isPresented: Binding(
            get: { capture.errorMessage != nil },
            set: { if !$0 { capture.errorMessage = nil } }
        )) {
            Button("Зрозуміло", role: .cancel) { capture.errorMessage = nil }
        } message: {
            Text(capture.errorMessage ?? "")
        }
        .sheet(isPresented: $showingPromptProfiles) {
            PromptProfilesView()
                .environmentObject(promptProfiles)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(teal, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Replyline").font(.system(size: 15, weight: .bold))
                    Text("LIVE ASSISTANT").font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.2).foregroundStyle(muted)
                }
            }
            .padding(.bottom, 38)

            Text("WORKSPACE").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(muted).padding(.bottom, 12)
            Label("Live assistant", systemImage: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(teal)
                .padding(.horizontal, 12).padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))

            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").foregroundStyle(teal)
                Text("Транскрипція зберігається локально").font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
            }
            .padding(.bottom, 15)
            Text("REPLYLINE · PREVIEW").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(muted.opacity(0.8))
        }
        .padding(22)
        .frame(width: 218)
        .background(.white)
        .overlay(alignment: .trailing) { Rectangle().fill(ink.opacity(0.07)).frame(width: 1) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Live assistant").font(.system(size: 27, weight: .bold, design: .rounded))
                Spacer()
                HStack(spacing: 7) {
                    Circle().fill(capture.isCapturing ? teal : Color.gray.opacity(0.45)).frame(width: 7, height: 7)
                    Text(capture.isCapturing ? "LISTENING" : (capture.isFinalizingTranscript ? "FINALIZING" : (capture.transcript.isEmpty ? "READY" : "DIALOG SAVED")))
                        .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(muted)
                }
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(.white, in: Capsule())
            }
            Text("Підказки для спілкування з клієнтами англійською").font(.system(size: 14)).foregroundStyle(muted)
        }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Джерело аудіо", note: "Обереш режим перед початком розмови")
            HStack(spacing: 12) {
                ForEach(AudioSource.allCases) { source in
                    Button {
                        guard !capture.isCapturing else { return }
                        capture.source = source
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: source.symbol)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(capture.source == source ? teal : muted)
                                .frame(width: 36, height: 36)
                                .background(capture.source == source ? teal.opacity(0.1) : Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(source.rawValue).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                                Text(source.detail).font(.system(size: 11)).foregroundStyle(muted).lineLimit(3).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                        .background(.white, in: RoundedRectangle(cornerRadius: 15))
                        .overlay(RoundedRectangle(cornerRadius: 15).stroke(capture.source == source ? teal : ink.opacity(0.08), lineWidth: capture.source == source ? 1.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(capture.isCapturing)
                }
            }
        }
    }

    private var aiProviderPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Модель для відповідей і конспекту", note: "GPT використовує план ChatGPT; Apple Intelligence працює локально")
            Picker("AI-провайдер", selection: $aiProvider.selected) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                if aiProvider.selected == .chatGPT {
                    if let email = chatGPT.accountEmail {
                        Label("Підключено: \(email)", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(teal)
                        Spacer()
                        Button("Від’єднати") { chatGPT.signOut() }
                            .font(.system(size: 11, weight: .medium)).buttonStyle(.plain).foregroundStyle(muted)
                    } else {
                        Text("Щоб використовувати GPT, увійди через ChatGPT")
                            .font(.system(size: 11)).foregroundStyle(muted)
                        Spacer()
                        Button {
                            Task {
                                do { try await chatGPT.signIn() }
                                catch { capture.errorMessage = error.localizedDescription }
                            }
                        } label: {
                            Label(chatGPT.isSigningIn ? "Очікую в браузері…" : "Продовжити через ChatGPT", systemImage: "arrow.up.right.square")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(teal)
                        }
                        .buttonStyle(.plain)
                        .disabled(chatGPT.isSigningIn)
                    }
                } else {
                    Label("Локальна обробка на цьому Mac", systemImage: "lock.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                    Spacer()
                }
            }
        }
        .padding(15)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ink.opacity(0.08), lineWidth: 1))
    }

    private var promptProfilePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Профіль промту", note: "Задай стиль і правила окремо для кожного типу задач")
            HStack(spacing: 12) {
                Menu {
                    ForEach(promptProfiles.profiles) { profile in
                        Button {
                            promptProfiles.select(profile.id)
                        } label: {
                            if profile.id == promptProfiles.selectedProfileID {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "text.book.closed").foregroundStyle(teal)
                        Text(promptProfiles.selectedProfile.name)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(ink)
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
                    }
                    .padding(13)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(ink.opacity(0.08), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)

                Button {
                    showingPromptProfiles = true
                } label: {
                    Label("Налаштувати", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(teal)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var captureControls: some View {
        HStack(spacing: 14) {
            Button(action: capture.toggleCapture) {
                Label(
                    capture.isFinalizingTranscript ? "Фіксую останні слова…" : (capture.isCapturing ? "Завершити діалог" : "Почати слухати"),
                    systemImage: capture.isCapturing ? "checkmark.circle.fill" : "waveform"
                )
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(capture.isCapturing ? Color(red: 0.78, green: 0.28, blue: 0.25) : teal, in: RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(.plain)
            .disabled(capture.isFinalizingTranscript)
            if capture.isCapturing {
                Button(action: capture.toggleRecognitionPause) {
                    Label(
                        capture.isRecognitionPaused ? "Продовжити слухати" : "Пауза — я відповідаю",
                        systemImage: capture.isRecognitionPaused ? "play.fill" : "pause.fill"
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(teal)
                    .padding(.horizontal, 13).padding(.vertical, 11)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            Text(capture.status).font(.system(size: 12)).foregroundStyle(muted)
            Spacer()
            Button("Очистити") { capture.clear() }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(muted).buttonStyle(.plain)
                .disabled(capture.isCapturing || capture.isFinalizingTranscript || capture.isGenerating || capture.isSummarizing)
        }
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Транскрипція діалогу", note: "Повний текст розмови · English")
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14).fill(.white)
                if capture.transcript.isEmpty {
                    Text(capture.isCapturing ? "Очікую на мовлення…" : "Тут з’явиться повний текст діалогу")
                        .font(.system(size: 13)).foregroundStyle(muted.opacity(0.8)).padding(15)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(capture.transcript)
                                    .font(.system(size: 14)).foregroundStyle(ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                Color.clear.frame(height: 1).id("transcript-end")
                            }
                        }
                        .onChange(of: capture.transcript) { _, _ in
                            proxy.scrollTo("transcript-end", anchor: .bottom)
                        }
                    }
                    .padding(15)
                }
            }
            .frame(height: 220)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(ink.opacity(0.08), lineWidth: 1))
            HStack {
                Label("English · on-device recognition", systemImage: "lock.fill")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
                Spacer()
                Button { capture.prepareReply(instructions: promptProfiles.selectedProfile.instructions) } label: {
                    Label(capture.isGenerating ? "Готую…" : "Підготувати відповідь", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(teal)
                }
                .buttonStyle(.plain)
                .disabled(capture.transcript.isEmpty || capture.isFinalizingTranscript || capture.isGenerating || capture.isSummarizing)
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                sectionTitle("Конспект розмови", note: "Створюється автоматично після завершення діалогу")
                Spacer()
                if !capture.summary.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(capture.summary, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Скопійовано" : "Копіювати", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(teal)
                    }
                    .buttonStyle(.plain)
                }
            }
            if capture.summary.isEmpty {
                Text(capture.isCapturing
                     ? "Заверши діалог, щоб створити конспект."
                     : (capture.isFinalizingTranscript ? "Фіксую останні слова, потім підготую конспект…" : "Готую короткий підсумок проблеми та наступних кроків…"))
                    .font(.system(size: 13)).foregroundStyle(muted)
                    .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
                    .padding(15)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
            } else {
                TextEditor(text: $capture.summary)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(9)
                    .frame(height: 150)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(ink.opacity(0.08), lineWidth: 1))
                    .onChange(of: capture.summary) { _, _ in capture.persistCurrentConversation() }
            }
            Button(action: capture.summarizeConversation) {
                Label(
                    capture.isSummarizing ? "Створюю конспект…" : (capture.summary.isEmpty ? "Створити конспект" : "Оновити конспект"),
                    systemImage: "doc.text.magnifyingglass"
                )
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(teal)
            }
            .buttonStyle(.plain)
            .disabled(capture.isCapturing || capture.isFinalizingTranscript || capture.isGenerating || capture.isSummarizing)
        }
    }

    private var replyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("Варіант відповіді", note: "English · editable")
                Spacer()
                if !capture.draft.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(capture.draft, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Скопійовано" : "Копіювати", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(teal)
                    }
                    .buttonStyle(.plain)
                }
            }
            TextEditor(text: $capture.draft)
                .id(capture.replyRevision)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(9)
                .frame(height: 106)
                .background(.white, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(ink.opacity(0.08), lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if capture.draft.isEmpty {
                        Text("Відповідь для клієнта з’явиться тут")
                            .font(.system(size: 13)).foregroundStyle(muted.opacity(0.8)).padding(.leading, 15).padding(.top, 17).allowsHitTesting(false)
                    }
                }
        }
    }

    private func sectionTitle(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(note).font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
        }
    }
}
