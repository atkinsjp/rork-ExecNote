//
//  AIGatewayClient.swift
//  IntelliDocScanSignPDF
//
//  Shared HTTP plumbing for every AI call: builds OpenAI-compatible requests
//  against the Rork Toolkit proxy (Vercel AI Gateway upstream), applies auth,
//  and maps transport failures to user-facing messages.
//

import Foundation
import OSLog

// MARK: - Errors

nonisolated enum AIGatewayError: LocalizedError, Equatable {
    case notConfigured
    case auth
    case insufficientBalance
    case rateLimited
    case payloadTooLarge
    case badResponse(Int)
    case transport(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "AI features aren't configured on this build. Everything else keeps working."
        case .auth:
            "AI features are temporarily unavailable. Please restart the app."
        case .insufficientBalance:
            "AI features are temporarily unavailable. Please try again later."
        case .rateLimited:
            "Too many AI requests. Wait a moment and try again."
        case .payloadTooLarge:
            "These pages are too large to send at once. Try scanning fewer pages."
        case .badResponse(let code):
            "The AI service returned an unexpected response (\(code)). Please try again."
        case .transport(let reason):
            "Network problem: \(reason)"
        case .emptyResponse:
            "The AI returned an empty result. Please try again."
        }
    }
}

// MARK: - Client

/// Thin static client over the toolkit proxy's OpenAI-compatible endpoint.
nonisolated enum AIGatewayClient {
    /// Multimodal model used for both handwriting transcription and rewrites.
    static let model = "google/gemini-2.5-flash"

    private static let logger = Logger(subsystem: "app.rork.scanvault", category: "ai-gateway")

    /// Chat-completions endpoint, nil when the toolkit URL is not injected.
    static var endpoint: URL? {
        let base = Config.EXPO_PUBLIC_TOOLKIT_URL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return nil }
        var trimmed = base
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: "\(trimmed)/v2/vercel/v1/chat/completions")
    }

    static var isConfigured: Bool { endpoint != nil }

    /// Builds a POST request with the proxy bearer token attached.
    static func makeRequest(body: [String: Any]) throws -> URLRequest {
        guard let endpoint else { throw AIGatewayError.notConfigured }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let secret = Config.EXPO_PUBLIC_RORK_TOOLKIT_SECRET_KEY
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Validates an HTTP response, mapping status codes to friendly errors.
    static func validate(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: body.prefix(200), encoding: .utf8) ?? ""
            logger.error("AI gateway \(http.statusCode, privacy: .public): \(detail, privacy: .public)")
            switch http.statusCode {
            case 401, 403: throw AIGatewayError.auth
            case 402: throw AIGatewayError.insufficientBalance
            case 413: throw AIGatewayError.payloadTooLarge
            case 429: throw AIGatewayError.rateLimited
            default: throw AIGatewayError.badResponse(http.statusCode)
            }
        }
    }

    // MARK: - Non-streaming completion

    /// Sends one request and returns the assistant message text.
    static func complete(body: [String: Any]) async throws -> String {
        let request = try makeRequest(body: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response, body: data)
            let decoded = try JSONDecoder().decode(ChatCompletion.self, from: data)
            guard let content = decoded.choices.first?.message?.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw AIGatewayError.emptyResponse }
            return content
        } catch let error as AIGatewayError {
            throw error
        } catch let error as DecodingError {
            logger.error("AI response decode failed: \(String(describing: error), privacy: .public)")
            throw AIGatewayError.badResponse(0)
        } catch {
            throw AIGatewayError.transport(error.localizedDescription)
        }
    }

    // MARK: - Streaming completion

    /// Opens an SSE stream and invokes `onDelta` for every generated token
    /// chunk as it arrives. Returns the fully accumulated text.
    static func stream(
        body: [String: Any],
        onDelta: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let request = try makeRequest(body: body)
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse {
                try validate(http, body: Data("[stream]".utf8))
            }

            var full = ""
            for try await line in bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("data: ") else { continue }
                let payload = String(trimmed.dropFirst(6))
                guard !payload.isEmpty, payload != "[DONE]" else { continue }
                guard let chunkData = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(StreamDelta.self, from: chunkData),
                      let delta = chunk.choices.first?.delta?.content
                else { continue }
                full += delta
                onDelta(delta)
            }
            guard !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIGatewayError.emptyResponse
            }
            return full
        } catch let error as AIGatewayError {
            throw error
        } catch {
            throw AIGatewayError.transport(error.localizedDescription)
        }
    }
}

// MARK: - Wire types

/// Standard chat-completion response (`choices[0].message.content`).
nonisolated struct ChatCompletion: Decodable {
    nonisolated struct Choice: Decodable {
        nonisolated struct Message: Decodable {
            let content: String?
        }
        let message: Message?
    }
    let choices: [Choice]
}

/// One SSE chunk from a streaming completion (`choices[0].delta.content`).
nonisolated struct StreamDelta: Decodable {
    nonisolated struct Choice: Decodable {
        nonisolated struct Delta: Decodable {
            let content: String?
        }
        let delta: Delta?
    }
    let choices: [Choice]
}
