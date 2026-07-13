import Foundation
import NovelCore

struct AICompletion: Sendable {
    var content: String
    var finishReason: String?
}

enum AIStreamValue: Sendable {
    case text(String)
    case finished(String?)
}

enum AIClientError: LocalizedError {
    case insecureEndpoint
    case missingKey
    case invalidResponse
    case httpStatus(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .insecureEndpoint: return "接口必须使用 HTTPS。"
        case .missingKey: return "此模型配置尚未保存 API Key。"
        case .invalidResponse: return "模型接口返回了无法识别的数据。"
        case .httpStatus(let code, let message): return "接口请求失败（HTTP \(code)）：\(message)"
        case .emptyResponse: return "模型没有返回正文。"
        }
    }
}

protocol AIChatClient {
    func complete(profile: AIEndpointProfile, apiKey: String, messages: [ChatMessage]) async throws -> AICompletion
    func stream(profile: AIEndpointProfile, apiKey: String, messages: [ChatMessage]) -> AsyncThrowingStream<AIStreamValue, Error>
}

final class OpenAICompatibleClient: AIChatClient {
    private struct RequestBody: Encodable {
        var model: String
        var messages: [ChatMessage]
        var temperature: Double
        var maxTokens: Int
        var stream: Bool

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case maxTokens = "max_tokens"
        }
    }

    private struct CompletionEnvelope: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message
            var finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        var choices: [Choice]
    }

    func complete(profile: AIEndpointProfile, apiKey: String, messages: [ChatMessage]) async throws -> AICompletion {
        try validate(profile: profile, apiKey: apiKey)
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let request = try makeRequest(profile: profile, apiKey: apiKey, messages: messages, stream: false)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = profile.timeoutSeconds
                let (data, response) = try await URLSession(configuration: configuration).data(for: request)
                try validate(response: response, data: data)
                let envelope = try JSONDecoder().decode(CompletionEnvelope.self, from: data)
                guard let choice = envelope.choices.first,
                      let content = choice.message.content,
                      !content.isEmpty else { throw AIClientError.emptyResponse }
                return AICompletion(content: content, finishReason: choice.finishReason)
            } catch {
                lastError = error
                guard attempt < 2, shouldRetry(error) else { throw error }
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
            }
        }
        throw lastError ?? AIClientError.invalidResponse
    }

    func stream(profile: AIEndpointProfile, apiKey: String, messages: [ChatMessage]) -> AsyncThrowingStream<AIStreamValue, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try validate(profile: profile, apiKey: apiKey)
                    var yieldedText = false
                    var lastError: Error?
                    for attempt in 0..<3 {
                        do {
                            let request = try makeRequest(profile: profile, apiKey: apiKey, messages: messages, stream: true)
                            let configuration = URLSessionConfiguration.ephemeral
                            configuration.timeoutIntervalForRequest = profile.timeoutSeconds
                            let (bytes, response) = try await URLSession(configuration: configuration).bytes(for: request)
                            try validate(response: response, data: Data())
                            var parser = SSEParser()
                            for try await line in bytes.lines {
                                try Task.checkCancellation()
                                let events = try parser.feed(line + "\n")
                                for event in events {
                                    switch event {
                                    case .text(let text):
                                        yieldedText = true
                                        continuation.yield(.text(text))
                                    case .finished(let reason): continuation.yield(.finished(reason))
                                    case .done: break
                                    }
                                }
                            }
                            for event in try parser.finish() {
                                switch event {
                                case .text(let text):
                                    yieldedText = true
                                    continuation.yield(.text(text))
                                case .finished(let reason): continuation.yield(.finished(reason))
                                case .done: break
                                }
                            }
                            continuation.finish()
                            return
                        } catch {
                            lastError = error
                            guard !yieldedText, attempt < 2, shouldRetry(error) else { throw error }
                            try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
                        }
                    }
                    throw lastError ?? AIClientError.invalidResponse
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    await DiagnosticLogger.shared.log(category: "AI", message: error.localizedDescription, secrets: [apiKey])
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func validate(profile: AIEndpointProfile, apiKey: String) throws {
        guard profile.isSecure else { throw AIClientError.insecureEndpoint }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIClientError.missingKey }
    }

    private func makeRequest(profile: AIEndpointProfile, apiKey: String, messages: [ChatMessage], stream: Bool) throws -> URLRequest {
        var request = URLRequest(url: profile.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = profile.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(profile.authenticationPrefix + apiKey, forHTTPHeaderField: profile.authenticationHeader)
        request.httpBody = try JSONEncoder().encode(RequestBody(model: profile.model, messages: messages, temperature: profile.temperature, maxTokens: profile.outputTokenLimit, stream: stream))
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AIClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8).map { String($0.prefix(500)) } ?? "未知错误"
            throw AIClientError.httpStatus(http.statusCode, DiagnosticLogger.redactAuthorization(message))
        }
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if let clientError = error as? AIClientError,
           case .httpStatus(let status, _) = clientError {
            return status == 429 || status >= 500
        }
        return error is URLError
    }
}
