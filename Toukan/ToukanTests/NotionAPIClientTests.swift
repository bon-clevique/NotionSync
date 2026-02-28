import XCTest
@testable import Toukan

// MARK: - MockURLProtocol

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequestBody: Data?
    nonisolated(unsafe) static var capturedRequests: [(url: URL, method: String, body: Data?)] = []

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

        Self.capturedRequests.append((url: request.url!, method: request.httpMethod ?? "GET", body: Self.lastRequestBody))

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
        MockURLProtocol.capturedRequests = []
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

    // MARK: - 9. fetchDatabase rejects invalid UUID

    func test_fetchDatabase_invalidUUID_throwsValidationError() async throws {
        MockURLProtocol.requestHandler = { _ in
            XCTFail("Request should not be sent for invalid UUID")
            return (makeResponse(statusCode: 200), Data())
        }

        do {
            _ = try await client.fetchDatabase(databaseId: "not-a-uuid")
            XCTFail("Expected NotionAPIError.validationError to be thrown")
        } catch let error as NotionAPIError {
            guard case .validationError(let message) = error else {
                XCTFail("Expected .validationError, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("not a valid UUID"))
        }
    }

    // MARK: - 10. fetchDataSourceName rejects invalid UUID

    func test_fetchDataSourceName_invalidUUID_throwsValidationError() async throws {
        MockURLProtocol.requestHandler = { _ in
            XCTFail("Request should not be sent for invalid UUID")
            return (makeResponse(statusCode: 200), Data())
        }

        do {
            _ = try await client.fetchDataSourceName(dataSourceId: "invalid!!!")
            XCTFail("Expected NotionAPIError.validationError to be thrown")
        } catch let error as NotionAPIError {
            guard case .validationError(let message) = error else {
                XCTFail("Expected .validationError, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("not a valid UUID"))
        }
    }

    // MARK: - Chunking helpers

    private func makeBlocks(_ count: Int) -> [NotionBlock] {
        (0..<count).map { .paragraph("Block \($0)") }
    }

    // MARK: - 11. Under 100 blocks: no append call

    func test_createPage_under100Blocks_doesNotCallAppend() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (makeResponse(statusCode: 200), successPageJSON)
        }

        _ = try await client.createPage(
            dataSourceId: "ds-123",
            title: "Test",
            litNoteId: nil,
            blocks: makeBlocks(50)
        )

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
        XCTAssertEqual(MockURLProtocol.capturedRequests[0].method, "POST")
    }

    // MARK: - 12. Over 100 blocks: appends remaining in chunks

    func test_createPage_over100Blocks_appendsRemainingInChunks() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (makeResponse(statusCode: 200), successPageJSON)
        }

        _ = try await client.createPage(
            dataSourceId: "ds-123",
            title: "Test",
            litNoteId: nil,
            blocks: makeBlocks(250)
        )

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 3)

        // Request 1: POST to /v1/pages with 100 blocks
        let req1 = MockURLProtocol.capturedRequests[0]
        XCTAssertEqual(req1.method, "POST")
        XCTAssertTrue(req1.url.absoluteString.hasSuffix("/v1/pages"))
        let body1 = try XCTUnwrap(req1.body)
        let json1 = try XCTUnwrap(try JSONSerialization.jsonObject(with: body1) as? [String: Any])
        let children1 = try XCTUnwrap(json1["children"] as? [[String: Any]])
        XCTAssertEqual(children1.count, 100)

        // Request 2: PATCH to /v1/blocks/page-123/children with 100 blocks
        let req2 = MockURLProtocol.capturedRequests[1]
        XCTAssertEqual(req2.method, "PATCH")
        XCTAssertTrue(req2.url.absoluteString.contains("blocks/page-123/children"))
        let body2 = try XCTUnwrap(req2.body)
        let json2 = try XCTUnwrap(try JSONSerialization.jsonObject(with: body2) as? [String: Any])
        let children2 = try XCTUnwrap(json2["children"] as? [[String: Any]])
        XCTAssertEqual(children2.count, 100)

        // Request 3: PATCH to /v1/blocks/page-123/children with 50 blocks
        let req3 = MockURLProtocol.capturedRequests[2]
        XCTAssertEqual(req3.method, "PATCH")
        XCTAssertTrue(req3.url.absoluteString.contains("blocks/page-123/children"))
        let body3 = try XCTUnwrap(req3.body)
        let json3 = try XCTUnwrap(try JSONSerialization.jsonObject(with: body3) as? [String: Any])
        let children3 = try XCTUnwrap(json3["children"] as? [[String: Any]])
        XCTAssertEqual(children3.count, 50)
    }

    // MARK: - 13. Exactly 100 blocks: no append call

    func test_createPage_exactly100Blocks_doesNotCallAppend() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (makeResponse(statusCode: 200), successPageJSON)
        }

        _ = try await client.createPage(
            dataSourceId: "ds-123",
            title: "Test",
            litNoteId: nil,
            blocks: makeBlocks(100)
        )

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
        XCTAssertEqual(MockURLProtocol.capturedRequests[0].method, "POST")
    }

    // MARK: - 14. appendBlocks sends PATCH with correct body

    func test_appendBlocks_sendsPATCH_withCorrectBody() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (makeResponse(statusCode: 200), Data("{}".utf8))
        }

        try await client.appendBlocks(pageId: "block-456", blocks: makeBlocks(3))

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
        let req = MockURLProtocol.capturedRequests[0]
        XCTAssertEqual(req.method, "PATCH")
        XCTAssertTrue(req.url.absoluteString.contains("blocks/block-456/children"))

        let bodyData = try XCTUnwrap(req.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let children = try XCTUnwrap(json["children"] as? [[String: Any]])
        XCTAssertEqual(children.count, 3)
    }

    // MARK: - 15. Append fails: throws rateLimited

    func test_createPage_appendFails_throwsError() async throws {
        var callCount = 0
        MockURLProtocol.requestHandler = { request in
            callCount += 1
            if callCount == 1 {
                // POST /pages succeeds
                return (makeResponse(statusCode: 200), successPageJSON)
            } else {
                // PATCH /blocks/.../children returns 429
                return (makeResponse(url: request.url!, statusCode: 429), Data())
            }
        }

        do {
            _ = try await client.createPage(
                dataSourceId: "ds-123",
                title: "Test",
                litNoteId: nil,
                blocks: makeBlocks(250)
            )
            XCTFail("Expected NotionAPIError.rateLimited to be thrown")
        } catch let error as NotionAPIError {
            guard case .rateLimited = error else {
                XCTFail("Expected .rateLimited, got \(error)")
                return
            }
        }
    }

}
