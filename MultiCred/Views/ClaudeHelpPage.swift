import MultiCredCore
import SwiftUI

/// "Ajuda com o Claude": the commands that connect MultiCred's help server to
/// Claude Code. The app only shows and copies them; it never edits Claude's
/// configuration (docs/SECURITY.md).
struct ClaudeHelpPage: View {
    let model: AppModel

    static var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/multicred-mcp")
    }

    @State private var copied: String?

    private var hasHelper: Bool {
        FileManager.default.isExecutableFile(atPath: Self.helperURL.path)
    }

    private var targets: [ClaudeHelpConnection.Target] {
        ClaudeHelpConnection.targets(config: model.config, executable: Self.helperURL, environment: model.environment)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tire dúvidas sobre o MultiCred com o seu Claude").font(.title2.weight(.semibold))
                Text("Conecte o ajudante do MultiCred ao Claude Code. Depois é só perguntar, por exemplo: “o que é o MultiCred?”, “como adiciono uma segunda conta do Claude?” ou “meu MultiCred está certo?”. O ajudante só lê: não altera nenhum arquivo e não mostra chaves nem tokens.")
                    .foregroundStyle(.secondary)

                if !hasHelper {
                    Label("Este build não inclui o ajudante (multicred-mcp). Gere o app com scripts/release.sh.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                if let warning = ClaudeHelpConnection.locationWarning(executable: Self.helperURL, environment: model.environment) {
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }

                Text("Cole o comando no Terminal. O MultiCred não mexe na configuração do Claude: quem roda é você. Cada pasta de Claude tem o seu comando.")
                    .font(.callout)

                ForEach(targets) { target in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(target.label).font(.headline)
                            commandBox(target.command)
                            HStack {
                                Button("Copiar comando") { copy(target.command, id: "add-\(target.id)") }
                                    .disabled(!hasHelper)
                                Text(copied == "add-\(target.id)" ? "Copiado" : "").font(.caption).foregroundStyle(.secondary)
                            }
                            DisclosureGroup("Desconectar") {
                                commandBox(target.removeCommand)
                                Button("Copiar comando") { copy(target.removeCommand, id: "remove-\(target.id)") }
                                Text(copied == "remove-\(target.id)" ? "Copiado" : "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Ajuda com o Claude")
    }

    private func commandBox(_ text: String) -> some View {
        Text(text)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func copy(_ text: String, id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = id
    }
}
