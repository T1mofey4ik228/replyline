# Replyline

Replyline is an open-source macOS assistant for drafting English customer-support replies.

## Current preview

- Choose between the Mac microphone (for an iPhone call on speakerphone) and Mac system audio (for an online meeting).
- Transcribe English speech using on-device Apple Speech recognition.
- Keep the active conversation transcript and Ukrainian issue summary in a local archive. Starting a new capture replaces the previous conversation; “Очистити” removes it immediately.
- Review and edit a reply draft before copying it.
- Choose GPT through Sign in with ChatGPT or Apple's on-device Foundation Models as the reply and summary provider. GPT requests use the eligible ChatGPT plan usage flow; they do not use an API key or API billing.
- ChatGPT sign-in credentials are stored in macOS Keychain. The app requests permission to use the ChatGPT plan in the browser. Users can disconnect the account in Replyline or manage the app's access and usage in ChatGPT Settings → Usage.
- When GPT is selected, Replyline sends the active transcript and selected prompt to OpenAI to draft a reply. Ending a conversation sends the transcript again to generate its summary. Captured audio itself is never uploaded or saved by Replyline.
- When Apple Intelligence is selected, reply and summary generation remain on-device. The transcript and archive continue to be stored locally either way.
- Generate an editable Ukrainian summary automatically after ending capture; it identifies the customer's issue, key details, request, and follow-up steps.

## Build

Requires macOS 26+ and the Swift toolchain. Run `sh scripts/build-app.sh` to produce `Replyline.app`. The script ad-hoc signs the local app so macOS can associate privacy permissions with it; it is a development build, not an App Store distribution.

## Audio behavior

- **iPhone call:** place the iPhone on speaker near the Mac microphone. iOS does not expose a normal cellular call's audio stream to a separate third-party app.
- **Mac meeting:** the prototype captures system audio with ScreenCaptureKit. The user must grant macOS screen/system-audio capture permission.
- Speech recognition is configured for English (US) and requests on-device recognition. Availability depends on macOS language support. Local reply generation depends on Apple Intelligence device and region support.
- Only transcript and summary text are archived locally; audio is not saved. “Очистити” removes the archived conversation and its summary. A new capture also replaces the previous conversation after the new audio source starts successfully.

## GPT and privacy

- The GPT option is optional. It uses Sign in with ChatGPT and requires the user's consent to use their ChatGPT plan. Usage counts against that plan and can be capped per app in ChatGPT Settings → Usage.
- Replyline sends only the text needed for the requested reply or summary. Do not capture or send customer information unless you are authorized to do so.
- Example conversations are not currently sent as training data. Replyline prompts can be edited locally in **Налаштувати**.

## License

Replyline is distributed under the MIT License. See [LICENSE](LICENSE).
