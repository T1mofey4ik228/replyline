import AppKit
import Combine
import CryptoKit
import Foundation
import Network
import Security

@MainActor
final class ChatGPTPlanClient: ObservableObject {
    static let shared = ChatGPTPlanClient()
    @Published private(set) var accountEmail: String?
    @Published private(set) var isSigningIn = false

    private let credentials = ChatGPTCredentialsStore()
    private let hostIDKey = "replyline.chatgpt.hostID.v1"
    private let model = "gpt-6.1-sol"

    init() {
        accountEmail = credentials.load()?.email
    }

    func signIn() async throws {
        guard !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }

        let hostID = UserDefaults.standard.string(forKey: hostIDKey) ?? "urn:uuid:\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(hostID, forKey: hostIDKey)
        let existing = credentials.load()
        let server = LoopbackOAuthServer()
        let redirectURI = try await server.start()
        let state = Self.randomToken()
        let nonce = Self.randomToken()
        let verifier = Self.randomToken()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()

        var components = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        var query = [
            URLQueryItem(name: "client_id", value: existing?.clientID ?? "dynamic_agent_client"),
            URLQueryItem(name: "ext_agent_host_id", value: hostID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"),
            URLQueryItem(name: "resource", value: "https://api.openai.com/v1"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge)
        ]
        if existing == nil { query.append(URLQueryItem(name: "agent_name_hint", value: "Replyline")) }
        else if let idToken = existing?.idToken { query.append(URLQueryItem(name: "id_token_hint", value: idToken)) }
        components.queryItems = query
        guard let authorizationURL = components.url else { throw ChatGPTError.invalidAuthorizationURL }
        NSWorkspace.shared.open(authorizationURL)

        let callback = try await server.waitForCallback()
        let callbackComponents = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        guard callbackComponents?.queryItems?.first(where: { $0.name == "state" })?.value == state else {
            throw ChatGPTError.invalidOAuthState
        }
        if let oauthError = callbackComponents?.queryItems?.first(where: { $0.name == "error" })?.value {
            throw ChatGPTError.authorizationDenied(oauthError)
        }
        guard let code = callbackComponents?.queryItems?.first(where: { $0.name == "code" })?.value,
              let issuedClientID = callbackComponents?.queryItems?.first(where: { $0.name == "client_id" })?.value ?? existing?.clientID else {
            throw ChatGPTError.missingAuthorizationCode
        }
        if let returnedClientID = callbackComponents?.queryItems?.first(where: { $0.name == "client_id" })?.value,
           let saved = existing, returnedClientID != saved.clientID {
            throw ChatGPTError.accountMismatch
        }

        var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "grant_type": "authorization_code",
            "client_id": issuedClientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI.absoluteString,
            "resource": "https://api.openai.com/v1"
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ChatGPTError.tokenExchangeFailed
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard token.scope.split(separator: " ").contains("chatgpt.tokens.use.direct") else {
            throw ChatGPTError.planAccessNotGranted
        }
        let identity = try await validateIDToken(token.id_token, audience: issuedClientID, nonce: nonce)
        if let saved = existing, saved.subject != identity.subject { throw ChatGPTError.accountMismatch }

        let stored = StoredCredentials(
            clientID: issuedClientID,
            email: identity.email ?? existing?.email ?? "ChatGPT account",
            subject: identity.subject,
            accessToken: token.access_token,
            refreshToken: token.refresh_token,
            idToken: token.id_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(token.expires_in)),
            scopes: token.scope
        )
        try credentials.save(stored)
        accountEmail = stored.email
    }

    func signOut() {
        credentials.delete()
        accountEmail = nil
    }

    func streamText(
        instructions: String,
        input: String,
        onUpdate: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        var stored = try await validCredentials()
        let body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": [["role": "user", "content": input]],
            "store": false,
            "stream": true
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(stored.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            stored = try await refresh(stored)
            request.setValue("Bearer \(stored.accessToken)", forHTTPHeaderField: "Authorization")
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ChatGPTError.inferenceFailed
        }

        var accumulated = ""
        var completed = false
        var eventType = ""
        for try await line in bytes.lines {
            if line.hasPrefix("event: ") { eventType = String(line.dropFirst(7)); continue }
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            switch eventType.isEmpty ? (event["type"] as? String ?? "") : eventType {
            case "response.output_text.delta":
                if let delta = event["delta"] as? String {
                    accumulated += delta
                    onUpdate(accumulated)
                }
            case "response.completed": completed = true
            case "response.failed", "error":
                let nested = event["error"] as? [String: Any]
                throw ChatGPTError.remoteFailure(nested?["code"] as? String ?? "unknown_error")
            default: break
            }
        }
        guard completed else { throw ChatGPTError.streamInterrupted }
        return accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validCredentials() async throws -> StoredCredentials {
        guard let saved = credentials.load() else { throw ChatGPTError.notConnected }
        if saved.expiresAt.timeIntervalSinceNow < 60 { return try await refresh(saved) }
        return saved
    }

    private func refresh(_ old: StoredCredentials) async throws -> StoredCredentials {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "grant_type": "refresh_token",
            "client_id": old.clientID,
            "refresh_token": old.refreshToken,
            "resource": "https://api.openai.com/v1"
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            credentials.delete()
            accountEmail = nil
            throw ChatGPTError.reconnectRequired
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        let updated = StoredCredentials(
            clientID: old.clientID, email: old.email, subject: old.subject,
            accessToken: token.access_token,
            refreshToken: token.refresh_token,
            idToken: token.id_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(token.expires_in)),
            scopes: token.scope
        )
        try credentials.save(updated)
        return updated
    }

    private func validateIDToken(_ token: String, audience: String, nonce: String) async throws -> Identity {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
              let headerData = Data(base64URL: String(parts[0])),
              let payloadData = Data(base64URL: String(parts[1])),
              let signature = Data(base64URL: String(parts[2])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              header["alg"] as? String == "RS256",
              let kid = header["kid"] as? String else { throw ChatGPTError.invalidIdentityToken }

        let configURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
        let (configData, _) = try await URLSession.shared.data(from: configURL)
        guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let jwksURLString = config["jwks_uri"] as? String,
              let jwksURL = URL(string: jwksURLString) else { throw ChatGPTError.invalidIdentityToken }
        let (keysData, _) = try await URLSession.shared.data(from: jwksURL)
        guard let jwks = try JSONSerialization.jsonObject(with: keysData) as? [String: Any],
              let keys = jwks["keys"] as? [[String: Any]],
              let jwk = keys.first(where: { $0["kid"] as? String == kid }),
              let modulusString = jwk["n"] as? String,
              let exponentString = jwk["e"] as? String,
              let modulus = Data(base64URL: modulusString),
              let exponent = Data(base64URL: exponentString) else { throw ChatGPTError.invalidIdentityToken }

        let keyData = Self.rsaPublicKeyDER(modulus: modulus, exponent: exponent)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modulus.count * 8
        ]
        var cfError: Unmanaged<CFError>?
        guard let publicKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &cfError) else {
            throw ChatGPTError.invalidIdentityToken
        }
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    signingInput as CFData, signature as CFData, &cfError) else {
            throw ChatGPTError.invalidIdentityToken
        }

        let issuer = payload["iss"] as? String
        let audiences = payload["aud"] as? [String] ?? [payload["aud"] as? String ?? ""]
        guard issuer == "https://auth.openai.com",
              audiences.contains(audience),
              (payload["exp"] as? TimeInterval ?? 0) > Date().timeIntervalSince1970,
              payload["nonce"] as? String == nonce,
              let subject = payload["sub"] as? String else { throw ChatGPTError.invalidIdentityToken }
        return Identity(subject: subject, email: payload["email"] as? String)
    }

    private static func rsaPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        func integer(_ data: Data) -> Data {
            var bytes = data
            while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
            if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
            return tlv(0x02, bytes)
        }
        let sequence = tlv(0x30, integer(modulus) + integer(exponent))
        let rsaOID = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
        return tlv(0x30, rsaOID + tlv(0x03, Data([0]) + sequence))
    }

    private static func tlv(_ tag: UInt8, _ value: Data) -> Data {
        var result = Data([tag])
        if value.count < 128 { result.append(UInt8(value.count)) }
        else {
            var count = value.count
            var length = [UInt8]()
            while count > 0 { length.insert(UInt8(count & 0xff), at: 0); count >>= 8 }
            result.append(0x80 | UInt8(length.count)); result.append(contentsOf: length)
        }
        result.append(value)
        return result
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func formBody(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "%20", with: "+").utf8)
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let id_token: String
        let expires_in: Int
        let scope: String
    }
    private struct Identity { let subject: String; let email: String? }
}

private struct StoredCredentials: Codable {
    var clientID: String
    var email: String
    var subject: String
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var expiresAt: Date
    var scopes: String
}

private final class ChatGPTCredentialsStore {
    private let service = "com.replyline.companion.chatgpt"
    private let account = "default"

    func load() -> StoredCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredCredentials.self, from: data)
    }

    func save(_ credentials: StoredCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            update.forEach { add[$0.key] = $0.value }
            let result = SecItemAdd(add as CFDictionary, nil)
            guard result == errSecSuccess else { throw ChatGPTError.credentialStorageFailed }
        } else if status != errSecSuccess { throw ChatGPTError.credentialStorageFailed }
    }

    func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

private final class LoopbackOAuthServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "replyline.oauth.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var resultContinuation: CheckedContinuation<URL, Error>?
    private var redirectURL: URL?

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] (state: NWListener.State) in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue,
                          let url = URL(string: "http://127.0.0.1:\(port)/auth/callback") else {
                        continuation.resume(throwing: ChatGPTError.callbackUnavailable); return
                    }
                    self.redirectURL = url
                    continuation.resume(returning: url)
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); resultContinuation = continuation; lock.unlock()
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let firstLine = request.components(separatedBy: "\r\n").first,
                  let target = firstLine.split(separator: " ").dropFirst().first,
                  let components = URLComponents(string: "http://127.0.0.1\(target)"),
                  components.path == "/auth/callback",
                  let redirectURL = self.redirectURL,
                  let callback = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false)?.url,
                  error == nil else { connection.cancel(); return }
            let body = "You can return to Replyline now."
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            guard let finalURL = URLComponents(string: "http://127.0.0.1\(target)")?.url,
                  callback.host == finalURL.host else { return }
            self.lock.lock(); let continuation = self.resultContinuation; self.resultContinuation = nil; self.lock.unlock()
            continuation?.resume(returning: finalURL)
        }
    }

    deinit { listener?.cancel() }
}

private enum ChatGPTError: LocalizedError {
    case invalidAuthorizationURL, invalidOAuthState, authorizationDenied(String), missingAuthorizationCode
    case accountMismatch, tokenExchangeFailed, planAccessNotGranted, invalidIdentityToken
    case credentialStorageFailed, callbackUnavailable, notConnected, reconnectRequired
    case inferenceFailed, streamInterrupted, remoteFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidAuthorizationURL: "Не вдалося підготувати вхід у ChatGPT."
        case .invalidOAuthState: "Перевірка входу не пройшла. Спробуй під’єднати ChatGPT ще раз."
        case .authorizationDenied: "Вхід або доступ до використання плану ChatGPT було скасовано."
        case .missingAuthorizationCode: "ChatGPT не повернув код входу. Спробуй ще раз."
        case .accountMismatch: "Повернутий обліковий запис не збігається з підключеним."
        case .tokenExchangeFailed: "Не вдалося обміняти код авторизації. Перевір інтернет і спробуй ще раз."
        case .planAccessNotGranted: "Дозвіл на використання плану ChatGPT не надано. Його можна дозволити в налаштуваннях ChatGPT."
        case .invalidIdentityToken: "Не вдалося перевірити обліковий запис OpenAI."
        case .credentialStorageFailed: "Не вдалося безпечно зберегти вхід у macOS Keychain."
        case .callbackUnavailable: "Не вдалося відкрити локальне з’єднання для повернення з браузера."
        case .notConnected: "Спочатку під’єднай ChatGPT у налаштуваннях Replyline."
        case .reconnectRequired: "Сеанс ChatGPT завершився. Під’єднай обліковий запис знову."
        case .inferenceFailed: "GPT не зміг обробити запит. Перевір ліміт використання в ChatGPT → Settings → Usage."
        case .streamInterrupted: "Потік відповіді GPT перервався до завершення. Спробуй ще раз."
        case .remoteFailure(let code): "Запит GPT не завершився: \(code). Перевір ChatGPT → Settings → Usage."
        }
    }
}

private extension Data {
    init?(base64URL value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
