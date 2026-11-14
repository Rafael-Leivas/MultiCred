import Foundation
import XCTest
@testable import MultiCredHelp

final class HelpToolsTests: XCTestCase {
    private let guide = Guide.bundled

    func testHowToCoversEverySeedTaskAndUnknown() async throws {
        let tool = HowToTool(guide: guide)
        let cases: [(query: String, id: String)] = [
            ("quero criar um novo perfil", "criar-perfil"),
            ("como adiciono uma segunda conta do Claude", "adicionar-conta-claude"),
            ("adicionar outra conta do github", "adicionar-conta-github"),
            ("trocar só a conta do Claude sem mexer no git", "trocar-so-conta-claude"),
            ("onde guardo minha chave da OpenAI", "chaves-de-api"),
            ("quero desinstalar", "desinstalar"),
            ("tenho o ~/Perfis antigo, como migrar", "migrar-perfis"),
        ]
        for (query, id) in cases {
            let entry = try XCTUnwrap(guide.tasks.first { $0.id == id }, "guide lacks task \(id)")
            let answer = try await tool.call(arguments: ["tarefa": .string(query)])
            XCTAssertTrue(answer.hasPrefix("# \(entry.title)"), "\(query) -> \(answer.prefix(60))")
        }
        let unknown = try await tool.call(arguments: ["tarefa": .string("como assar uma pizza")])
        XCTAssertTrue(unknown.contains("Não encontrei"))
        for task in guide.tasks { XCTAssertTrue(unknown.contains(task.id), "unknown answer lists \(task.id)") }
        let empty = try await tool.call(arguments: [:])
        XCTAssertTrue(empty.contains("Tarefas disponíveis"))
    }

    func testTroubleshootCoversFourSymptomsAndNoMatch() async throws {
        let tool = TroubleshootTool(guide: guide)
        let cases: [(query: String, id: String)] = [
            ("meu terminal aberto não trocou de conta", "terminal-nao-trocou"),
            ("o login do Claude falhou", "login-claude-falhou"),
            ("o gh está na conta errada do github", "gh-conta-errada"),
            ("o Mac pediu a senha do Keychain", "keychain-pediu-senha"),
        ]
        for (query, id) in cases {
            let entry = try XCTUnwrap(guide.problems.first { $0.id == id }, "guide lacks problem \(id)")
            let answer = try await tool.call(arguments: ["sintoma": .string(query)])
            XCTAssertTrue(answer.hasPrefix("# \(entry.title)"), "\(query) -> \(answer.prefix(60))")
        }
        let none = try await tool.call(arguments: ["sintoma": .string("a lua é de queijo")])
        XCTAssertTrue(none.contains("Não encontrei"))
        for problem in guide.problems { XCTAssertTrue(none.contains(problem.id)) }
    }

    func testGuideParsesEntries() {
        XCTAssertEqual(guide.version, "0.1.0")
        XCTAssertGreaterThanOrEqual(guide.tasks.count, 7)
        XCTAssertGreaterThanOrEqual(guide.problems.count, 4)
        XCTAssertTrue(guide.tasks.allSatisfy { !$0.keywords.isEmpty && !$0.body.isEmpty })
        XCTAssertFalse(guide.about.contains("Manutenção"), "maintainer note stays out of answers")
    }

    func testKeywordLinesAddUpAndFencedHeadingsStayInTheBody() {
        let markdown = """
        # Guia
        versão: 1.2.3

        ## Tarefas

        ### a · Primeira
        palavras-chave: um, dois
        palavras-chave: tres
        sintomas: quatro
        Corpo com bloco:
        ```
        ## nao-e-secao
        versão: 9.9.9
        ```
        fim
        """
        let parsed = Guide(markdown: markdown)
        XCTAssertEqual(parsed.version, "1.2.3")
        XCTAssertEqual(parsed.tasks.first?.keywords, ["um", "dois", "tres", "quatro"])
        XCTAssertTrue(parsed.tasks.first?.body.contains("## nao-e-secao") == true)
        XCTAssertTrue(parsed.tasks.first?.body.hasSuffix("fim") == true)
    }
}
