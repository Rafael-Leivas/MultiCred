import Foundation

/// "O que é o MultiCred": the guide's overview (R-01).
public struct AboutTool: MCPTool {
    public let name = "sobre_o_multicred"
    public let description = "Explica o que é o MultiCred, o que ele altera no Mac, o que nunca toca e onde ficam as telas. Use para qualquer pergunta geral sobre o app."
    public let inputSchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])])
    let guide: Guide

    public init(guide: Guide) { self.guide = guide }

    public func call(arguments: [String: JSONValue]) async throws -> String {
        "MultiCred \(guide.version)\n\n\(guide.about)"
    }
}
