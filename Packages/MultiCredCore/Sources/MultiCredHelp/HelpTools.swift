import Foundation

private func entryText(_ entry: Guide.Entry) -> String { "# \(entry.title)\n\n\(entry.body)" }

private func catalog(_ entries: [Guide.Entry], heading: String) -> String {
    "\(heading):\n" + entries.map { "- \($0.id): \($0.title)" }.joined(separator: "\n")
}

private func text(_ arguments: [String: JSONValue], _ key: String) throws -> String? {
    guard let value = arguments[key] else { return nil }
    guard let string = value.stringValue else { throw MCPToolError("O argumento \"\(key)\" deve ser texto.") }
    return string
}

private func answer(for query: String?, in entries: [Guide.Entry], missing: String, heading: String) -> String {
    guard let query, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return catalog(entries, heading: heading) }
    let ranked = GuideSearch.rank(entries, for: query)
    guard let best = ranked.first else { return "\(missing)\n\n\(catalog(entries, heading: heading))" }
    var text = entryText(best)
    let others = ranked.dropFirst().prefix(2)
    if !others.isEmpty {
        text += "\n\nTambém pode ajudar: " + others.map { "\($0.title) (\($0.id))" }.joined(separator: "; ")
    }
    return text
}

/// "Como faço X": the guide's step by step for a task (R-02).
public struct HowToTool: MCPTool {
    public let name = "como_fazer"
    public let description = "Passo a passo de uma tarefa no MultiCred (criar perfil, adicionar conta Claude ou GitHub, trocar só a conta Claude, chaves de API, desinstalar, migrar de ~/Perfis, verificar, conectar ao Claude). Passe a tarefa com as palavras do usuário; sem argumento, lista as tarefas."
    public let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["tarefa": .object(["type": .string("string"), "description": .string("O que o usuário quer fazer, em linguagem natural.")])]),
    ])
    let guide: Guide

    public init(guide: Guide) { self.guide = guide }

    public func call(arguments: [String: JSONValue]) async throws -> String {
        answer(for: try text(arguments, "tarefa"), in: guide.tasks, missing: "Não encontrei essa tarefa no guia.", heading: "Tarefas disponíveis")
    }
}

/// "Algo deu errado": probable causes and fixes for a symptom (R-03).
public struct TroubleshootTool: MCPTool {
    public let name = "solucao_de_problemas"
    public let description = "Causas prováveis e correção para um sintoma ou erro do MultiCred (terminal que não trocou, login do Claude falhou, gh na conta errada, Keychain pedindo senha, sessão antiga). Passe o sintoma com as palavras do usuário; sem argumento, lista os sintomas conhecidos. Para olhar o estado real da máquina use diagnostico_do_meu_multicred."
    public let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["sintoma": .object(["type": .string("string"), "description": .string("O problema ou mensagem de erro, em linguagem natural.")])]),
    ])
    let guide: Guide

    public init(guide: Guide) { self.guide = guide }

    public func call(arguments: [String: JSONValue]) async throws -> String {
        answer(for: try text(arguments, "sintoma"), in: guide.problems, missing: "Não encontrei esse sintoma no guia.", heading: "Sintomas conhecidos")
    }
}
