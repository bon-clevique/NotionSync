import Foundation
import os

// MARK: - Error Types

enum NotionAPIError: Error, Sendable {
    case unauthorized
    case rateLimited(retryAfter: Int?)
    case validationError(message: String)
    case notFound
    case serverError(statusCode: Int)
    case networkError(underlying: Error)
    case decodingError(underlying: Error)
}

extension NotionAPIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Notion API: Unauthorized (401). Check your API token."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Notion API: Rate limited (429). Retry after \(retryAfter)s."
            }
            return "Notion API: Rate limited (429)."
        case .validationError(let message):
            return "Notion API: Validation error (400) — \(message)"
        case .notFound:
            return "Notion API: Not found (404)."
        case .serverError(let statusCode):
            return "Notion API: Server error (\(statusCode))."
        case .networkError(let underlying):
            return "Notion API: Network error — \(underlying.localizedDescription)"
        case .decodingError(let underlying):
            return "Notion API: Decoding error — \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Block Types

/// Represents a Notion block for the `children` array of a page creation request.
struct NotionBlock: Encodable, Sendable {
    let object: String = "block"
    let type: BlockType

    enum BlockType: String, Encodable, Sendable {
        case heading1 = "heading_1"
        case heading2 = "heading_2"
        case heading3 = "heading_3"
        case paragraph
    }

    /// Shared content struct used inside every block's rich_text array.
    struct RichText: Encodable, Sendable {
        let type: String = "text"
        let text: TextContent

        struct TextContent: Encodable, Sendable {
            let content: String
        }
    }

    /// Payload carried by each block type (always a `rich_text` array).
    struct BlockContent: Encodable, Sendable {
        let richText: [RichText]

        enum CodingKeys: String, CodingKey {
            case richText = "rich_text"
        }
    }

    // Single non-optional backing store for all block types.
    private let content: BlockContent

    // MARK: Encoding

    enum CodingKeys: String, CodingKey {
        case object
        case type
        case heading1 = "heading_1"
        case heading2 = "heading_2"
        case heading3 = "heading_3"
        case paragraph
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(object, forKey: .object)
        try container.encode(type.rawValue, forKey: .type)

        switch type {
        case .heading1:
            try container.encode(content, forKey: .heading1)
        case .heading2:
            try container.encode(content, forKey: .heading2)
        case .heading3:
            try container.encode(content, forKey: .heading3)
        case .paragraph:
            try container.encode(content, forKey: .paragraph)
        }
    }

    // MARK: Private init

    private init(type: BlockType, content: BlockContent) {
        self.type = type
        self.content = content
    }

    // MARK: Factory methods

    private static func richText(for text: String) -> [RichText] {
        [RichText(text: RichText.TextContent(content: text))]
    }

    static func heading1(_ text: String) -> NotionBlock {
        NotionBlock(type: .heading1, content: BlockContent(richText: richText(for: text)))
    }

    static func heading2(_ text: String) -> NotionBlock {
        NotionBlock(type: .heading2, content: BlockContent(richText: richText(for: text)))
    }

    static func heading3(_ text: String) -> NotionBlock {
        NotionBlock(type: .heading3, content: BlockContent(richText: richText(for: text)))
    }

    static func paragraph(_ text: String) -> NotionBlock {
        NotionBlock(type: .paragraph, content: BlockContent(richText: richText(for: text)))
    }
}

// MARK: - Request Types

struct CreatePageRequest: Encodable, Sendable {

    // MARK: Parent

    struct Parent: Encodable, Sendable {
        let dataSourceId: String

        enum CodingKeys: String, CodingKey {
            case dataSourceId = "data_source_id"
        }
    }

    // MARK: Properties

    struct Properties: Encodable, Sendable {

        struct TitleProperty: Encodable, Sendable {
            struct TitleItem: Encodable, Sendable {
                struct TextContent: Encodable, Sendable {
                    let content: String
                }
                let text: TextContent
            }
            let title: [TitleItem]
        }

        struct RelationProperty: Encodable, Sendable {
            struct RelationItem: Encodable, Sendable {
                let id: String
            }
            let relation: [RelationItem]
        }

        let name: TitleProperty
        let litNotes: RelationProperty?

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case litNotes = "Lit Notes"
        }
    }

    // MARK: Stored properties

    let parent: Parent
    let properties: Properties
    let children: [NotionBlock]

    // MARK: CodingKeys — all keys are already in the desired form

    enum CodingKeys: String, CodingKey {
        case parent
        case properties
        case children
    }
}

// MARK: - Response Types

struct NotionPage: Decodable, Sendable {
    let id: String
    let url: String?
}

// MARK: - Data Source Response

struct DataSourceResponse: Decodable, Sendable {
    let id: String
    let title: [RichTextItem]

    struct RichTextItem: Decodable, Sendable {
        let plainText: String

        enum CodingKeys: String, CodingKey {
            case plainText = "plain_text"
        }
    }

    var name: String {
        title.map(\.plainText).joined()
    }
}

// MARK: - Database Response (for resolving share links)

struct DatabaseResponse: Decodable, Sendable {
    let id: String
    let title: [DataSourceResponse.RichTextItem]
    let dataSources: [DataSourceReference]

    struct DataSourceReference: Decodable, Sendable {
        let id: String
        let name: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, title
        case dataSources = "data_sources"
    }

    var databaseName: String {
        title.map(\.plainText).joined()
    }
}

// MARK: - API Error Response

private struct NotionErrorResponse: Decodable, Sendable {
    let message: String?
}

// MARK: - Client

struct NotionAPIClient: Sendable {

    // MARK: Private state

    private let token: String
    private let session: URLSession

    private static let logger = Logger(
        subsystem: "com.clevique.Toukan",
        category: "NotionAPI"
    )

    private static let baseURL = URL(string: "https://api.notion.com/v1")!
    private static let notionVersion = "2025-09-03"

    // MARK: Init

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    // MARK: - Public API

    /// Creates a new Notion page.
    /// - Parameters:
    ///   - dataSourceId: The Notion database (data source) ID to create the page in.
    ///   - title:        The page title (maps to the "Name" property).
    ///   - litNoteId:    Optional page ID to set as a "Lit Notes" relation.
    ///   - blocks:       Body blocks to append as page children.
    /// - Returns: The created `NotionPage`.
    func createPage(
        dataSourceId: String,
        title: String,
        litNoteId: String?,
        blocks: [NotionBlock]
    ) async throws -> NotionPage {
        let url = Self.baseURL.appendingPathComponent("pages")

        // Build properties
        let nameItem = CreatePageRequest.Properties.TitleProperty.TitleItem(
            text: .init(content: title)
        )
        let litNotes: CreatePageRequest.Properties.RelationProperty?
        if let litNoteId {
            litNotes = .init(relation: [.init(id: litNoteId)])
        } else {
            litNotes = nil
        }
        let properties = CreatePageRequest.Properties(
            name: .init(title: [nameItem]),
            litNotes: litNotes
        )

        let body = CreatePageRequest(
            parent: .init(dataSourceId: dataSourceId),
            properties: properties,
            children: blocks
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(to: &request)

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            Self.logger.error("createPage: failed to encode request body — \(error, privacy: .public)")
            throw NotionAPIError.networkError(underlying: error)
        }

        Self.logger.info("createPage: POST \(url.absoluteString, privacy: .public) title='\(title, privacy: .public)'")

        let (data, response) = try await performRequest(request)

        do {
            let page = try JSONDecoder().decode(NotionPage.self, from: data)
            Self.logger.info("createPage: created page id=\(page.id, privacy: .public)")
            return page
        } catch {
            Self.logger.error("createPage: decoding failed — \(error, privacy: .public)")
            throw NotionAPIError.decodingError(underlying: error)
        }
    }

    /// Retrieves database info including data sources by calling `GET /databases/{database_id}`.
    /// Used to resolve a share link (which contains a database_id) to a data_source_id.
    /// - Parameter databaseId: The database ID extracted from a Notion share link.
    /// - Returns: The `DatabaseResponse` containing data sources.
    func fetchDatabase(databaseId: String) async throws -> DatabaseResponse {
        try Self.validateUUID(databaseId, label: "database ID")
        let url = Self.baseURL.appendingPathComponent("databases/\(databaseId)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(to: &request)

        Self.logger.info("fetchDatabase: GET \(url.absoluteString, privacy: .public)")

        let (data, _) = try await performRequest(request)

        do {
            let response = try JSONDecoder().decode(DatabaseResponse.self, from: data)
            Self.logger.info("fetchDatabase: '\(response.databaseName, privacy: .public)' with \(response.dataSources.count, privacy: .public) data source(s)")
            return response
        } catch {
            Self.logger.error("fetchDatabase: decoding failed — \(error, privacy: .public)")
            throw NotionAPIError.decodingError(underlying: error)
        }
    }

    /// Retrieves the data source name by calling `GET /data_sources/{data_source_id}`.
    /// - Parameter dataSourceId: The data source ID to look up.
    /// - Returns: The data source name (title).
    func fetchDataSourceName(dataSourceId: String) async throws -> String {
        try Self.validateUUID(dataSourceId, label: "data source ID")
        let url = Self.baseURL.appendingPathComponent("data_sources/\(dataSourceId)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(to: &request)

        Self.logger.info("fetchDataSourceName: GET \(url.absoluteString, privacy: .public)")

        let (data, _) = try await performRequest(request)

        do {
            let response = try JSONDecoder().decode(DataSourceResponse.self, from: data)
            let name = response.name
            Self.logger.info("fetchDataSourceName: '\(name, privacy: .public)'")
            return name
        } catch {
            Self.logger.error("fetchDataSourceName: decoding failed — \(error, privacy: .public)")
            throw NotionAPIError.decodingError(underlying: error)
        }
    }

    // MARK: - Private helpers

    /// Validates that the given string is a well-formed UUID (8-4-4-4-12 hex).
    private static func validateUUID(_ value: String, label: String) throws {
        let pattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw NotionAPIError.validationError(message: "Invalid \(label): '\(value)' is not a valid UUID")
        }
    }

    /// Attaches Authorization and Notion-Version headers.
    private func applyHeaders(to request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    /// Executes the request and maps HTTP status codes to `NotionAPIError`.
    private func performRequest(
        _ request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let urlResponse: URLResponse

        do {
            (data, urlResponse) = try await session.data(for: request)
        } catch {
            Self.logger.error("performRequest: network error — \(error, privacy: .public)")
            throw NotionAPIError.networkError(underlying: error)
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            Self.logger.error("performRequest: non-HTTP response")
            throw NotionAPIError.networkError(
                underlying: URLError(.badServerResponse)
            )
        }

        let statusCode = httpResponse.statusCode
        Self.logger.debug("performRequest: HTTP \(statusCode, privacy: .public)")

        switch statusCode {
        case 200...299:
            return (data, httpResponse)

        case 400:
            let message = decodedErrorMessage(from: data) ?? "Bad request"
            Self.logger.error("performRequest: 400 \(message, privacy: .public)")
            throw NotionAPIError.validationError(message: message)

        case 401:
            Self.logger.error("performRequest: 401 Unauthorized")
            throw NotionAPIError.unauthorized

        case 404:
            Self.logger.error("performRequest: 404 Not Found")
            throw NotionAPIError.notFound

        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Int($0) }
            Self.logger.warning("performRequest: 429 Rate limited retryAfter=\(retryAfter.map { "\($0)" } ?? "nil", privacy: .public)")
            throw NotionAPIError.rateLimited(retryAfter: retryAfter)

        default:
            Self.logger.error("performRequest: unexpected status \(statusCode, privacy: .public)")
            throw NotionAPIError.serverError(statusCode: statusCode)
        }
    }

    /// Attempts to decode a human-readable error message from the Notion error response body.
    private func decodedErrorMessage(from data: Data) -> String? {
        try? JSONDecoder().decode(NotionErrorResponse.self, from: data).message
    }
}
