import Darwin
import Foundation

/// A read-only tool the help server offers to Claude.
public protocol MCPTool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: JSONValue { get }
    func call(arguments: [String: JSONValue]) async throws -> String
}

public struct MCPToolError: Error { public let message: String; public init(_ message: String) { self.message = message } }

/// Model Context Protocol server over newline-delimited JSON-RPC (stdio
/// transport). Hand written on purpose: no dependency, no networking. It
/// serves tools only; every tool is read-only (docs/SECURITY.md).
public actor MCPServer {
    public static let serverName = "multicred"
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let tools: [any MCPTool]
    private let version: String

    public init(tools: [any MCPTool], version: String = Guide.bundled.version) {
        self.tools = tools
        self.version = version
    }

    /// The fixed tool set of the help server: guide tools plus the diagnostic.
    /// Every tool is read-only; adding one is a spec change (docs/SECURITY.md).
    public static func help(guide: Guide, diagnostics: DiagnosticService) -> MCPServer {
        MCPServer(tools: [
            AboutTool(guide: guide),
            HowToTool(guide: guide),
            TroubleshootTool(guide: guide),
            DiagnosticTool(service: diagnostics),
        ], version: guide.version)
    }

    /// One incoming line -> the reply line, or nil for notifications.
    public func handle(line: String) async -> String? {
        guard let data = line.data(using: .utf8), let message = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return encode(errorReply(id: .null, code: -32700, message: "Parse error"))
        }
        guard let object = message.objectValue else {
            return encode(errorReply(id: .null, code: -32600, message: "Invalid request"))  // batches are not supported
        }
        let id = object["id"]
        guard let method = object["method"]?.stringValue else {
            if object["result"] != nil || object["error"] != nil { return nil }  // a client's reply to us: never answered
            return id.map { encode(errorReply(id: $0, code: -32600, message: "Invalid request")) } ?? nil
        }
        let params = object["params"]?.objectValue ?? [:]
        guard let id else { return nil }  // notification: never answered

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue
            let chosen = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil } ?? Self.supportedProtocolVersions[0]
            return encode(result(id: id, .object([
                "protocolVersion": .string(chosen),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string(Self.serverName), "version": .string(version)]),
                "instructions": .string("Responde dúvidas sobre o MultiCred e diagnostica o estado local, somente leitura. Comece por sobre_o_multicred."),
            ])))
        case "ping":
            return encode(result(id: id, .object([:])))
        case "tools/list":
            let list = tools.map { tool in
                JSONValue.object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema,
                    "annotations": .object(["readOnlyHint": .bool(true), "destructiveHint": .bool(false), "openWorldHint": .bool(false)]),
                ])
            }
            return encode(result(id: id, .object(["tools": .array(list)])))
        case "tools/call":
            guard let name = params["name"]?.stringValue, let tool = tools.first(where: { $0.name == name }) else {
                return encode(errorReply(id: id, code: -32602, message: "Unknown tool"))
            }
            let arguments = params["arguments"]?.objectValue ?? [:]
            do {
                let text = try await tool.call(arguments: arguments)
                return encode(result(id: id, toolResult(text, isError: false)))
            } catch let error as MCPToolError {
                return encode(result(id: id, toolResult(error.message, isError: true)))
            } catch {
                // The raw error can quote command arguments or tool stderr; keep it from the model.
                return encode(result(id: id, toolResult("Não consegui concluir esta consulta (erro interno).", isError: true)))
            }
        default:
            return encode(errorReply(id: id, code: -32601, message: "Method not found"))
        }
    }

    /// Reads stdin line by line until EOF. Requests run concurrently, so a slow
    /// tool never blocks `ping`; replies are written one at a time.
    public func serve(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async {
        let lines = AsyncStream<String> { continuation in
            let reader = Thread {
                var buffer = Data()
                var bytes = [UInt8](repeating: 0, count: 65536)
                while true {
                    // read(2) returns what has arrived (FileHandle.availableData raises an
                    // Objective-C exception on read errors, read(upToCount:) waits to fill the buffer).
                    let count = read(input.fileDescriptor, &bytes, bytes.count)
                    if count <= 0 { break }
                    buffer.append(contentsOf: bytes[0..<count])
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                        buffer.removeSubrange(buffer.startIndex...newline)
                        if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continuation.yield(line) }
                    }
                }
                // A last request without a trailing newline is still a request.
                let rest = String(decoding: buffer, as: UTF8.self)
                if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continuation.yield(rest) }
                continuation.finish()
            }
            reader.stackSize = 1 << 20
            reader.start()
        }
        let writer = ReplyWriter(output)
        await withTaskGroup(of: Void.self) { group in
            for await line in lines {
                group.addTask {
                    if let reply = await self.handle(line: line) { writer.write(reply) }
                }
            }
        }
    }

    private func toolResult(_ text: String, isError: Bool) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(isError)])
    }

    private func result(id: JSONValue, _ value: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": value])
    }

    private func errorReply(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }

    private func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "{}"
    }
}

/// Serializes writes to stdout. `write(contentsOf:)` throws on a closed pipe
/// instead of raising, so a vanished client ends the replies quietly.
private final class ReplyWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(_ handle: FileHandle) { self.handle = handle }

    func write(_ reply: String) {
        lock.withLock { try? handle.write(contentsOf: Data((reply + "\n").utf8)) }
    }
}
