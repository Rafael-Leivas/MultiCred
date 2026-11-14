import Foundation
import XCTest
@testable import MultiCredHelp

final class MCPServerTests: XCTestCase {
    private func call(_ server: MCPServer, _ json: String) async throws -> [String: Any] {
        let line = await server.handle(line: json)
        let reply = try XCTUnwrap(line)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }

    func testInitializeListAndAbout() async throws {
        let server = MCPServer(tools: [AboutTool(guide: .bundled)])

        let initialize = try await call(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        let result = try XCTUnwrap(initialize["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "multicred")

        let notification = await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(notification, "notifications get no reply")

        let list = try await call(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["sobre_o_multicred"])

        let about = try await call(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sobre_o_multicred","arguments":{}}}"#)
        let content = try XCTUnwrap(((about["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first)
        let text = try XCTUnwrap(content["text"] as? String)
        XCTAssertTrue(text.contains("MultiCred"))
        XCTAssertTrue(text.contains("O que o app nunca toca"))

        let unknown = try await call(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"apagar_tudo"}}"#)
        XCTAssertNotNil(unknown["error"], "unknown tool is a protocol error")
    }

    private struct SlowTool: MCPTool {
        let name = "lenta"
        let description = "slow"
        let inputSchema: JSONValue = .object(["type": .string("object")])
        func call(arguments: [String: JSONValue]) async throws -> String {
            try await Task.sleep(for: .seconds(1))
            return "done"
        }
    }

    func testResponsesAndBatchesAndConcurrentPing() async throws {
        let server = MCPServer(tools: [SlowTool()])

        // A response from the client (id, no method) is never answered.
        let ignored = await server.handle(line: #"{"jsonrpc":"2.0","id":9,"result":{}}"#)
        XCTAssertNil(ignored)

        // A batch array is an invalid request, not a parse error.
        let batch = try await call(server, #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
        XCTAssertEqual((batch["error"] as? [String: Any])?["code"] as? Int, -32600)

        // ping is answered while a slow tool call is still running.
        let input = Pipe()
        let output = Pipe()
        let serving = Task { await server.serve(input: input.fileHandleForReading, output: output.fileHandleForWriting) }
        let lines = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"lenta"}}"# + "\n"
            + #"{"jsonrpc":"2.0","id":2,"method":"ping"}"# + "\n"
        input.fileHandleForWriting.write(Data(lines.utf8))
        let first = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        XCTAssertTrue(first.contains(#""id":2"#), "ping answered first, got: \(first)")
        try input.fileHandleForWriting.close()
        await serving.value
        let rest = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        XCTAssertTrue(rest.contains(#""id":1"#), "slow call still answered before exit")
    }

    private struct LeakyError: Error, CustomStringConvertible { var description: String { "TOKEN-123 raw stderr" } }
    private struct BoomTool: MCPTool {
        let name = "boom"
        let description = "fails"
        let inputSchema: JSONValue = .object(["type": .string("object")])
        func call(arguments: [String: JSONValue]) async throws -> String { throw LeakyError() }
    }

    func testLastLineWithoutNewlineCrlfAndErrorsStayGeneric() async throws {
        let server = MCPServer(tools: [BoomTool(), HowToTool(guide: .bundled)])

        // EOF right after a request with no trailing newline, after a blank CRLF line.
        let input = Pipe()
        let output = Pipe()
        let serving = Task { await server.serve(input: input.fileHandleForReading, output: output.fileHandleForWriting) }
        let request = "\r\n" + #"{"jsonrpc":"2.0","id":5,"method":"ping"}"#
        input.fileHandleForWriting.write(Data(request.utf8))
        try input.fileHandleForWriting.close()
        await serving.value
        try output.fileHandleForWriting.close()
        let replies = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(replies.contains(#""id":5"#), "final request without newline is answered: \(replies)")
        XCTAssertFalse(replies.contains("-32700"), "a blank CRLF line is not a parse error")

        // An unexpected error never reaches the model verbatim.
        let boom = try await call(server, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"boom"}}"#)
        let result = try XCTUnwrap(boom["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = try XCTUnwrap(((result["content"] as? [[String: Any]])?.first?["text"]) as? String)
        XCTAssertFalse(text.contains("TOKEN-123"))

        // A non-text argument is an error, not a silent catalog.
        let bad = try await call(server, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"como_fazer","arguments":{"tarefa":42}}}"#)
        XCTAssertEqual((bad["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    func testConcurrentDiagnosticCallsShareOneReport() async {
        let coalescer = ReportCoalescer()
        let counter = Counter()
        async let first = coalescer.report { await counter.bump(); try? await Task.sleep(for: .milliseconds(300)); return "relatorio" }
        async let second = coalescer.report { await counter.bump(); return "outro" }
        let results = await [first, second]
        let runs = await counter.value
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(results, ["relatorio", "relatorio"])
    }

    private actor Counter { var value = 0; func bump() { value += 1 } }
}
