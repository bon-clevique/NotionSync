import XCTest
@testable import Toukan

// MARK: - MockURLProtocol

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Capture body: URLSession may place it in httpBody or httpBodyStream
        if let body = request.httpBody {
            Self.lastRequestBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4096)
                if count > 0 { data.append(buffer, count: count) }
            }
            stream.close()
            Self.lastRequestBody = data
        }

        guard let handler = Self.requestHandler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Helpers

private func makeResponse(
    url: URL = URL(string: "https://api.notion.com/v1/pages")!,
    statusCode: Int,
    headers: [String: String]? = nil
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
}

private let successPageJSON = #"{"id":"page-123","url":"https://notion.so/page-123"}"#
    .data(using: .utf8)!

// MARK: - NotionAPIClientTests

final class NotionAPIClientTests: XCTestCase {
    private var client: NotionAPIClient!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        client = NotionAPIClient(token: "test-token", session: session)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.lastRequestBody = nil
        client = nil
        session = nil
        super.tearDown()
    }

    // MARK: - 1. Correct headers

    func test_createPage_sendsCorrectHeaders() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Notion-Version"), "2025-09-03")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return (makeResponse(statusCode: 200), successPageJSON)
        }

        let page = try await client.createPage(
            dataSourceId: "ds-123",
            title: "Test Title",
            litNoteId: nil,
            blocks: [.paragraph("Hello")]
        )
        XCTAssertEqual(page.id, "page-123")
    }

    // MARK: - 2. Correct request body

    func test_createPage_sendsCorrectBody() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (makeResponse(statusCode: 200), successPageJSON)
        }

        _ = try await client.createPage(
            dataSourceId: "ds-123",
            title: "Test",
            litNoteId: nil,
            blocks: [.paragraph("text")]
        )

        let bodyData = try XCTUnwrap(MockURLProtocol.lastRequestBody, "Request body should not be nil")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        // Verify parent.data_source_id
        let parent = try XCTUnwrap(body["parent"] as? [String: Any])
        XCTAssertEqual(parent["data_source_id"] as? String, "ds-123")

        // Verify properties.Name.title[0].text.content
        let properties = try XCTUnwrap(body["properties"] as? [String: Any])
        let nameProperty = try XCTUnwrap(properties["Name"] as? [String: Any])
        let titleArray = try XCTUnwrap(nameProperty["title"] as? [[String: Any]])
        let firstTitle = try XCTUnwrap(titleArray.first)
        let textObject = try XCTUnwrap(firstTitle["text"] as? [String: Any])
        XCTAssertEqual(textObject["content"] as? String, "Test")

        // Verify "Lit Notes" key is NOT present
        XCTAssertNil(properties["Lit Notes"], "Lit Notes should not be present when litNoteId is nil")
    }

    // MARK: - 3. Lit Notes relation included when litNoteId is provided

    func test_createPage_withLitNoteId_includesRelation() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (makeResponse(statusCode: 200), successPageJSON)
        }

        _ = try await client.createPage(
            dataSourceId: "ds-123",
            title: "Test",
            litNoteId: "note-abc",
            blocks: []
        )

        let bodyData = try XCTUnwrap(MockURLProtocol.lastRequestBody)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let properties = try XCTUnwrap(body["properties"] as? [String: Any])
        let litNotes = try XCTUnwrap(properties["Lit Notes"] as? [String: Any], "Lit Notes should be present")
        let relation = try XCTUnwrap(litNotes["relation"] as? [[String: Any]])
        let firstRelation = try XCTUnwrap(relation.first)
        XCTAssertEqual(firstRelation["id"] as? String, "note-abc")
    }

    // MARK: - 4. 401 throws unauthorized

    func test_createPage_401_throwsUnauthorized() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (makeResponse(statusCode: 401), Data())
        }

        do {
            _ = try await client.createPage(
                dataSourceId: "ds-123",
                title: "Test",
                litNoteId: nil,
                blocks: []
            )
            XCTFail("Expected NotionAPIError.unauthorized to be thrown")
        } catch let error as NotionAPIError {
            guard case .unauthorized = error else {
                XCTFail("Expected .unauthorized, got \(error)")
                return
            }
        }
    }

    // MARK: - 5. 429 throws rateLimited with Retry-After

    func test_createPage_429_throwsRateLimited() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (makeResponse(statusCode: 429, headers: ["Retry-After": "30"]), Data())
        }

        do {
            _ = try await client.createPage(
                dataSourceId: "ds-123",
                title: "Test",
                litNoteId: nil,
                blocks: []
            )
            XCTFail("Expected NotionAPIError.rateLimited to be thrown")
        } catch let error as NotionAPIError {
            guard case .rateLimited(let retryAfter) = error else {
                XCTFail("Expected .rateLimited, got \(error)")
                return
            }
            XCTAssertEqual(retryAfter, 30)
        }
    }

    // MARK: - 6. 400 throws validationError with message

    func test_createPage_400_throwsValidationError() async throws {
        let bodyData = #"{"message":"Invalid property"}"#.data(using: .utf8)!

        MockURLProtocol.requestHandler = { _ in
            return (makeResponse(statusCode: 400), bodyData)
        }

        do {
            _ = try await client.createPage(
                dataSourceId: "ds-123",
                title: "Test",
                litNoteId: nil,
                blocks: []
            )
            XCTFail("Expected NotionAPIError.validationError to be thrown")
        } catch let error as NotionAPIError {
            guard case .validationError(let message) = error else {
                XCTFail("Expected .validationError, got \(error)")
                return
            }
            XCTAssertEqual(message, "Invalid property")
        }
    }

    // MARK: - 7. 404 throws notFound

    func test_createPage_404_throwsNotFound() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (makeResponse(statusCode: 404), Data())
        }

        do {
            _ = try await client.createPage(
                dataSourceId: "ds-123",
                title: "Test",
                litNoteId: nil,
                blocks: []
            )
            XCTFail("Expected NotionAPIError.notFound to be thrown")
        } catch let error as NotionAPIError {
            guard case .notFound = error else {
                XCTFail("Expected .notFound, got \(error)")
                return
            }
        }
    }

    // MARK: - 8. 500 throws serverError

    func test_createPage_500_throwsServerError() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (makeResponse(statusCode: 500), Data())
        }

        do {
            _ = try await client.createPage(
                dataSourceId: "ds-123",
                title: "Test",
                litNoteId: nil,
                blocks: []
            )
            XCTFail("Expected NotionAPIError.serverError to be thrown")
        } catch let error as NotionAPIError {
            guard case .serverError(let statusCode) = error else {
                XCTFail("Expected .serverError, got \(error)")
                return
            }
            XCTAssertEqual(statusCode, 500)
        }
    }

}
