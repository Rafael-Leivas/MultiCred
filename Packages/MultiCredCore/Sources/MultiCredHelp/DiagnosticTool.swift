import Foundation

/// "Meu MultiCred está certo?": the read-only report (R-04).
public struct DiagnosticTool: MCPTool {
    public let name = "diagnostico_do_meu_multicred"
    public let description = "Diagnóstico somente leitura do MultiCred neste Mac: versão, ferramentas (git, gh, Claude Code), perfil ativo, shells com o bloco instalado, contas Claude e GitHub, e os mesmos checks da tela Verificar (ok, aviso, erro) com a explicação e o botão do app para corrigir. Nunca altera nada nem mostra segredos."
    public let inputSchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])])
    let service: DiagnosticService
    private let coalescer = ReportCoalescer()

    public init(service: DiagnosticService) { self.service = service }

    public func call(arguments: [String: JSONValue]) async throws -> String {
        // Calls that overlap share one run, so a looping client cannot pile up shell/CLI processes.
        await coalescer.report { await service.report() }
    }
}

/// Lets simultaneous callers await one in-flight report instead of starting their own.
actor ReportCoalescer {
    private var inFlight: Task<String, Never>?

    func report(_ make: @escaping @Sendable () async -> String) async -> String {
        if let inFlight { return await inFlight.value }
        let task = Task { await make() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }
}
