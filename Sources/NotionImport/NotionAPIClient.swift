/**
 * File: NotionAPIClient.swift
 * ---------------------------
 * Layer: Notion
 * Description: Notion's API as the importer reaches it: requests through the transport the host fills, kept to
 *              Notion's rate, waiting and trying again on 429 and 5xx answers and while the network is lost, and lists
 *              read page by page.
 *
 * Authors: Bahey Shalash
 * Version: 0.1
 * Date: 27/11/2026
 */

import ImporterCore

/// A request to Notion's API or to a file Notion links to. The host adds what the importer never sees: the token, as
/// `Authorization: Bearer …`, on requests to Notion's API only (`isNotionAPI`), never on a file's address.
public struct NotionRequest: Equatable, Sendable {
    public var method: String
    /// The whole address, `https://api.notion.com/v1/…` or a file's own address.
    public var url: String
    public var headers: [NotionHeader]
    public var body: [UInt8]?
    /// Whether the request goes to Notion's API, so the host adds the token.
    public var isNotionAPI: Bool

    public init(method: String, url: String, headers: [NotionHeader] = [], body: [UInt8]? = nil, isNotionAPI: Bool) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.isNotionAPI = isNotionAPI
    }
}

/// A header of a request or an answer.
public struct NotionHeader: Equatable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// An answer: its status, headers and body.
public struct NotionResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [NotionHeader]
    public var body: [UInt8]

    public init(status: Int, headers: [NotionHeader] = [], body: [UInt8]) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// The first header of this name, compared without regard to case.
    public func header(_ name: String) -> String? {
        let lowered = name.lowercased()
        return headers.first { header in header.name.lowercased() == lowered }?.value
    }
}

/// Sends requests: `URLSession` in a linked host, the plugin runtime's `requestUrl` in the WebAssembly build, recorded
/// answers in the tests. Throwing means the request did not get an answer (the network is lost or the request timed
/// out), which the client waits on and tries again.
public protocol NotionTransport: Sendable {
    func send(_ request: NotionRequest) async throws -> NotionResponse
}

/// The time the client keeps its rate by and waits on.
public protocol NotionClock: Sendable {
    /// Milliseconds on a clock that never goes back, from any origin.
    func nowMilliseconds() async -> Int64
    /// Waits `milliseconds`, throwing when the task is cancelled.
    func sleep(milliseconds: Int64) async throws
}

/// Why a request to Notion failed for good.
public enum NotionAPIError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 401: the token is wrong or was revoked.
    case unauthorized(String)
    /// 403 or 404: the object is not shared with the integration, or no longer is, or does not exist.
    case notShared(String)
    /// Another answer Notion refused the request with, its status and Notion's own message.
    case refused(status: Int, message: String)
    /// Notion kept answering 429 or 5xx, or the network stayed lost, through every wait.
    case unavailable(String)
    /// An answer that is not the JSON Notion sends.
    case unreadableAnswer(String)

    public var description: String {
        switch self {
        case .unauthorized(let message):
            return "Notion refused the token (\(message)). Make a new one in Notion's integrations and import again."
        case .notShared(let message):
            return "Notion did not give this page or database (\(message)): it is not shared with the integration, or not any more."
        case .refused(let status, let message):
            return "Notion refused a request (\(status): \(message))."
        case .unavailable(let message):
            return "Notion could not be reached (\(message))."
        case .unreadableAnswer(let message):
            return "Notion answered something the importer cannot read (\(message))."
        }
    }
}

/// How the client keeps to Notion's limits. Notion allows three requests a second on average and some bursts above
/// it, and answers 429 with `Retry-After` beyond that.
public struct NotionRequestPolicy: Equatable, Sendable {
    /// Requests a second, on average.
    public var requestsPerSecond: Int
    /// Requests that may go at once before the average holds.
    public var burst: Int
    /// The first wait after a 5xx answer or a lost network, doubled at each failure up to `longestWaitMilliseconds`.
    public var firstWaitMilliseconds: Int64
    public var longestWaitMilliseconds: Int64
    /// How long a request is tried again before it fails for good: Notion answering 429 or 5xx, or the network lost.
    public var giveUpAfterMilliseconds: Int64

    public init(requestsPerSecond: Int = 3, burst: Int = 10, firstWaitMilliseconds: Int64 = 1_000, longestWaitMilliseconds: Int64 = 60_000,
                giveUpAfterMilliseconds: Int64 = 15 * 60_000) {
        self.requestsPerSecond = requestsPerSecond
        self.burst = burst
        self.firstWaitMilliseconds = firstWaitMilliseconds
        self.longestWaitMilliseconds = longestWaitMilliseconds
        self.giveUpAfterMilliseconds = giveUpAfterMilliseconds
    }
}

/// Notion's API: each request sent through the transport at Notion's rate and tried again while Notion is busy or the
/// network is lost, each answer read as JSON, and lists read to their end.
public actor NotionAPIClient {
    /// The API version every request asks for, the one with data sources.
    public static let version = "2025-09-03"
    public static let baseAddress = "https://api.notion.com/v1/"

    private let transport: any NotionTransport
    private let clock: any NotionClock
    private let policy: NotionRequestPolicy
    /// The token bucket: requests that may go now, and when it was last filled.
    private var availableRequests: Double
    private var lastFillMilliseconds: Int64?
    /// Requests sent, answers 429 and 5xx, and waits for a lost network, for the report and the tests.
    public private(set) var sentRequestCount = 0
    public private(set) var retriedRequestCount = 0

    public init(transport: any NotionTransport, clock: any NotionClock, policy: NotionRequestPolicy = NotionRequestPolicy()) {
        self.transport = transport
        self.clock = clock
        self.policy = policy
        availableRequests = Double(policy.burst)
    }

    // MARK: Endpoints

    /// `GET /v1/<path>` with `query` added, read as JSON.
    public func get(_ path: String, query: [(name: String, value: String)] = []) async throws -> JSONValue {
        try await json(NotionRequest(method: "GET", url: NotionAPIClient.address(path, query: query), headers: apiHeaders(hasBody: false), isNotionAPI: true))
    }

    /// `POST /v1/<path>` with the JSON `body`, read as JSON.
    public func post(_ path: String, body: JSONValue) async throws -> JSONValue {
        try await json(NotionRequest(method: "POST", url: NotionAPIClient.address(path), headers: apiHeaders(hasBody: true),
                                     body: Array(body.text.utf8), isNotionAPI: true))
    }

    /// Every result of a list Notion gives a page at a time (`results`, `has_more`, `next_cursor`): `GET` with
    /// `start_cursor` in the query, or `POST` with it in the body.
    public func allResults(get path: String, query: [(name: String, value: String)] = []) async throws -> [JSONValue] {
        var results: [JSONValue] = []
        var cursor: String?
        repeat {
            var pageQuery = query + [("page_size", "100")]
            if let cursor { pageQuery.append(("start_cursor", cursor)) }
            let page = try await get(path, query: pageQuery)
            results += page["results"]?.elements ?? []
            cursor = page["has_more"]?.bool == true ? page["next_cursor"]?.string : nil
        } while cursor != nil
        return results
    }

    public func allResults(post path: String, body: [(key: String, value: JSONValue)] = []) async throws -> [JSONValue] {
        var results: [JSONValue] = []
        var cursor: String?
        repeat {
            var pageBody = body + [("page_size", .number("100"))]
            if let cursor { pageBody.append(("start_cursor", .string(cursor))) }
            let page = try await post(path, body: .object(pageBody))
            results += page["results"]?.elements ?? []
            cursor = page["has_more"]?.bool == true ? page["next_cursor"]?.string : nil
        } while cursor != nil
        return results
    }

    /// The bytes of a file Notion links to (an upload's signed address, valid about an hour), without the token.
    public func download(_ url: String) async throws -> [UInt8] {
        let response = try await send(NotionRequest(method: "GET", url: url, isNotionAPI: false))
        guard (200..<300).contains(response.status) else {
            throw NotionAPIError.refused(status: response.status, message: "the file at \(url) was not given")
        }
        return response.body
    }

    // MARK: Sending

    private func apiHeaders(hasBody: Bool) -> [NotionHeader] {
        var headers = [NotionHeader(name: "Notion-Version", value: NotionAPIClient.version)]
        if hasBody { headers.append(NotionHeader(name: "Content-Type", value: "application/json")) }
        return headers
    }

    static func address(_ path: String, query: [(name: String, value: String)] = []) -> String {
        var address = baseAddress + path
        for (index, item) in query.enumerated() {
            address += (index == 0 ? "?" : "&") + item.name + "=" + percentEncoded(item.value)
        }
        return address
    }

    /// `text` with every byte but letters, digits and `-._~` escaped, as a query value needs.
    static func percentEncoded(_ text: String) -> String {
        let hexadecimal: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]
        var result = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                result.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                result.append("%")
                result.append(hexadecimal[Int(byte >> 4)])
                result.append(hexadecimal[Int(byte & 0xF)])
            }
        }
        return result
    }

    private func json(_ request: NotionRequest) async throws -> JSONValue {
        let response = try await send(request)
        let answer: JSONValue
        do {
            answer = try JSONValue.parse(response.body)
        } catch {
            throw NotionAPIError.unreadableAnswer("status \(response.status), \(response.body.count) bytes")
        }
        guard (200..<300).contains(response.status) else {
            let message = answer["message"]?.string ?? answer["code"]?.string ?? "no message"
            switch response.status {
            case 401: throw NotionAPIError.unauthorized(message)
            case 403, 404: throw NotionAPIError.notShared(message)
            default: throw NotionAPIError.refused(status: response.status, message: message)
            }
        }
        return answer
    }

    /// Sends `request` at Notion's rate and tries it again on 429, 5xx and a lost network, until the policy gives up.
    private func send(_ request: NotionRequest) async throws -> NotionResponse {
        let started = await clock.nowMilliseconds()
        var wait = policy.firstWaitMilliseconds
        while true {
            try Task.checkCancellation()
            if request.isNotionAPI { try await takeRequest() }
            sentRequestCount += 1
            let response: NotionResponse
            do {
                response = try await transport.send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await waitBeforeTryingAgain(&wait, since: started, reason: "the network was lost (\(ImportReport.text(describing: error)))")
                continue
            }
            if response.status == 429 {
                // Notion says how long to wait, in seconds.
                let retryAfter = response.header("Retry-After").flatMap { Int64($0.trimmingSpaces()) }.map { $0 * 1_000 }
                if let retryAfter, retryAfter > wait { wait = retryAfter }
                try await waitBeforeTryingAgain(&wait, since: started, reason: "Notion asked to slow down (429)")
                continue
            }
            if (500..<600).contains(response.status) {
                try await waitBeforeTryingAgain(&wait, since: started, reason: "Notion answered \(response.status)")
                continue
            }
            return response
        }
    }

    private func waitBeforeTryingAgain(_ wait: inout Int64, since started: Int64, reason: String) async throws {
        let now = await clock.nowMilliseconds()
        guard now - started + wait <= policy.giveUpAfterMilliseconds else { throw NotionAPIError.unavailable(reason) }
        retriedRequestCount += 1
        try await clock.sleep(milliseconds: wait)
        wait = min(wait * 2, policy.longestWaitMilliseconds)
    }

    /// Waits until the token bucket holds a request, then takes it.
    private func takeRequest() async throws {
        while true {
            let now = await clock.nowMilliseconds()
            if let last = lastFillMilliseconds {
                availableRequests = min(Double(policy.burst), availableRequests + Double(now - last) * Double(policy.requestsPerSecond) / 1_000)
            }
            lastFillMilliseconds = now
            if availableRequests >= 1 {
                availableRequests -= 1
                return
            }
            let missing = 1 - availableRequests
            let waitMilliseconds = Int64((missing * 1_000 / Double(policy.requestsPerSecond)).rounded(.up))
            try await clock.sleep(milliseconds: max(1, waitMilliseconds))
        }
    }
}
