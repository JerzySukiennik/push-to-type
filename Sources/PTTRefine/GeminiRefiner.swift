import Foundation
import PTTSupport

/// A ``TextRefiner`` backed by Google's Gemini API.
///
/// This is the one place in PushToType that talks to the network, and only for modes the
/// user has explicitly given a prompt and a shortcut. Raw dictation never reaches it.
///
/// The key travels in the `x-goog-api-key` header rather than the URL query string, so it
/// stays out of logs and request lines. Only the transcript is sent, alongside the mode's
/// instruction — no vocabulary, no history, nothing the user did not just say.
public struct GeminiRefiner: TextRefiner {

    private let modelProvider: @Sendable () -> String
    private let keyProvider: @Sendable () -> String?
    private let session: URLSession

    /// - Parameters:
    ///   - modelProvider: reads the Gemini model id on demand, so changing it in Settings
    ///     takes effect on the next dictation without rebuilding anything.
    ///   - keyProvider: reads the API key on demand, for the same reason. Defaults to the
    ///     keychain.
    public init(
        modelProvider: @escaping @Sendable () -> String,
        keyProvider: @escaping @Sendable () -> String? = { APIKeyStore.geminiKey },
        session: URLSession = .shared
    ) {
        self.modelProvider = modelProvider
        self.keyProvider = keyProvider
        self.session = session
    }

    public func refine(_ text: String, instruction: String) async throws -> String {
        guard let key = keyProvider() else { throw PTTError.refinementKeyMissing }
        let model = modelProvider()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var request = URLRequest(url: try endpoint(model: model))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(
            GenerateRequest(instruction: Self.systemInstruction(instruction), text: trimmed)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw PTTError.refinementFailed(reason: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PTTError.refinementFailed(reason: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PTTError.refinementFailed(reason: Self.describe(status: http.statusCode, body: data))
        }

        let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        let output = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw PTTError.refinementEmpty }
        return output
    }

    // MARK: - Wire format

    private func endpoint(model: String) throws -> URL {
        guard let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        ) else {
            throw PTTError.refinementFailed(reason: "invalid model name")
        }
        return url
    }

    /// Wraps the mode's instruction with the guardrails that keep the response insertable.
    ///
    /// Without this the model tends to explain itself, wrap the answer in quotes, or offer
    /// alternatives — all of which would be typed straight into the user's document. The
    /// output goes nowhere a human reviews it first, so the constraints have to be explicit.
    private static func systemInstruction(_ instruction: String) -> String {
        """
        \(instruction)

        Zasady wyjścia (bezwzględne):
        - Zwróć wyłącznie przepisany tekst, gotowy do wklejenia.
        - Bez komentarzy, wyjaśnień, cudzysłowów ani wariantów.
        - Zachowaj język oryginału.
        - Jeśli tekst jest pusty lub bez treści, zwróć go bez zmian.
        """
    }

    private static func describe(status: Int, body: Data) -> String {
        // Gemini returns a JSON error with a human-readable message; surface it when present.
        if let error = try? JSONDecoder().decode(ErrorEnvelope.self, from: body),
           !error.error.message.isEmpty {
            return "HTTP \(status): \(error.error.message)"
        }
        return "HTTP \(status)"
    }

    // MARK: Codable payloads

    private struct GenerateRequest: Encodable {
        let systemInstruction: Instruction
        let contents: [Content]
        let generationConfig: Config

        init(instruction: String, text: String) {
            systemInstruction = Instruction(parts: [Part(text: instruction)])
            contents = [Content(role: "user", parts: [Part(text: text)])]
            // Low but non-zero: the task is rewriting, not invention, and a little slack
            // reads more naturally than greedy decoding.
            generationConfig = Config(temperature: 0.3)
        }

        struct Instruction: Encodable { let parts: [Part] }
        struct Content: Encodable { let role: String; let parts: [Part] }
        struct Part: Encodable { let text: String }
        struct Config: Encodable { let temperature: Double }
    }

    private struct GenerateResponse: Decodable {
        let candidates: [Candidate]?

        /// The first candidate's text, joined across parts, or empty.
        var text: String {
            candidates?.first?.content.parts.map(\.text).joined() ?? ""
        }

        struct Candidate: Decodable { let content: Content }
        struct Content: Decodable { let parts: [Part] }
        struct Part: Decodable { let text: String }
    }

    private struct ErrorEnvelope: Decodable {
        let error: Payload
        struct Payload: Decodable { let message: String }
    }
}
