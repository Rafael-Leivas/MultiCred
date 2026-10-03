import MultiCredCore
import SwiftUI

/// "Ajustes" (design 07). Folder rules, commit protection and the global
/// shortcut are deferred to after v1 (TODOS.md).
struct SettingsPage: View {
    let model: AppModel
    let navigator: MainNavigator

    @State private var toolPaths: [Tool: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Geral") {
                    Toggle("Abrir ao iniciar a sessão", isOn: binding(\MultiCredCore.Settings.openAtLogin))
                    Picker("Ao trocar de perfil, mostrar", selection: binding(\MultiCredCore.Settings.switchFeedback)) {
                        Text("HUD breve e notificação").tag(SwitchFeedback.hud)
                        Text("Só notificação").tag(SwitchFeedback.notification)
                        Text("Nada").tag(SwitchFeedback.none)
                    }
                }
                Section {
                    ForEach(ShellKind.allCases, id: \.self) { shell in
                        Toggle(isOn: shellBinding(shell)) {
                            VStack(alignment: .leading) {
                                Text(shell.rawValue)
                                Text(files(for: shell)).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Shells")
                } footer: {
                    Text("Nos shells marcados, terminais já abertos também trocam de conta a cada prompt. Mudar aqui reescreve só o bloco do MultiCred nesses arquivos, com backup.")
                }
                Section("Ferramentas encontradas") {
                    ForEach(Tool.allCases, id: \.self) { tool in
                        LabeledContent(tool.displayName, value: toolPaths[tool] ?? "procurando…")
                            .font(.callout)
                    }
                }
                Section("Diagnóstico") {
                    HStack {
                        Button("Abrir pasta de logs") { NSWorkspace.shared.open(model.environment.logsDirectory) }
                        Button("Copiar diagnóstico") {
                            Task {
                                let text = await model.diagnostics()
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                            }
                        }
                    }
                }
                if model.isInstalled {
                    Section {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "trash").foregroundStyle(.red).font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Desinstalar e restaurar arquivos originais").font(.headline).foregroundStyle(.red)
                                Text("Remove o bloco do MultiCred dos arquivos de shell e do gitconfig, a variável do Claude Code no launchd e as chaves de API do Keychain. As contas continuam logadas nas próprias ferramentas.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Desinstalar…") { navigator.push(.uninstall) }
                                .tint(.red)
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle("Ajustes")
        .task {
            for tool in Tool.allCases {
                toolPaths[tool] = await model.tools.locate(tool)?.path ?? "não encontrado"
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<MultiCredCore.Settings, T>) -> Binding<T> {
        Binding(
            get: { model.config.settings[keyPath: keyPath] },
            set: { value in
                var settings = model.config.settings
                settings[keyPath: keyPath] = value
                model.updateSettings(settings)
            }
        )
    }

    private func shellBinding(_ shell: ShellKind) -> Binding<Bool> {
        Binding(
            get: { model.config.settings.enabledShells.contains(shell) },
            set: { enabled in
                var settings = model.config.settings
                settings.enabledShells.removeAll { $0 == shell }
                if enabled { settings.enabledShells.append(shell) }
                settings.enabledShells.sort { $0.rawValue < $1.rawValue }
                model.updateSettings(settings)
            }
        )
    }

    private func files(for shell: ShellKind) -> String {
        if shell == .fish { return model.environment.abbreviate(Integrations.fishConfFile(environment: model.environment).path) }
        return Integrations.rcFiles(for: shell, environment: model.environment).map { model.environment.abbreviate($0.path) }.joined(separator: ", ")
    }
}

/// Uninstall confirmation and result, as a page in the same window.
struct UninstallPage: View {
    let model: AppModel
    let navigator: MainNavigator

    @State private var logoutClaude = false
    @State private var report: UninstallReport?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let report {
                result(report)
            } else {
                Text("Desinstalar o MultiCred").font(.title2.weight(.semibold))
                Text("Estas são as mudanças. Só o bloco do MultiCred é removido de cada arquivo; o resto fica como você deixou.")
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.uninstallPreview()) { FileChangeView(change: $0) }
                        Text("Também: launchctl unsetenv CLAUDE_CONFIG_DIR, apagar as chaves de API do Keychain, desligar a abertura ao iniciar a sessão. Os backups vão para ~/Library/Application Support/MultiCred-backups-<data>.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Toggle("Também sair das contas Claude com pasta própria (claude auth logout)", isOn: $logoutClaude)
                HStack {
                    Spacer()
                    Button("Cancelar") { navigator.back() }.keyboardShortcut(.cancelAction)
                    Button("Desinstalar") {
                        Task {
                            running = true
                            report = await model.uninstall(logoutCreatedClaudeAccounts: logoutClaude)
                            running = false
                        }
                    }
                    .tint(.red)
                    .buttonStyle(.borderedProminent)
                    .disabled(running)
                }
            }
        }
        .padding(20)
        .navigationTitle("Desinstalar")
    }

    @ViewBuilder private func result(_ report: UninstallReport) -> some View {
        Label("MultiCred desinstalado", systemImage: "checkmark.circle.fill").font(.title2.weight(.semibold)).foregroundStyle(.green)
        if !report.changedFiles.isEmpty {
            Text("Arquivos restaurados: \(report.changedFiles.joined(separator: ", "))")
        }
        if let backups = report.backupsKeptAt {
            Text("Backups guardados em \(backups).").foregroundStyle(.secondary)
        }
        ForEach(report.manualSteps, id: \.self) { Label($0, systemImage: "hand.raised").foregroundStyle(.orange) }
        ForEach(report.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
        Text("Abra um novo Terminal para que os shells deixem de carregar o MultiCred. Você já pode mover o app para o Lixo.")
            .foregroundStyle(.secondary)
        Spacer()
        HStack {
            Spacer()
            Button("Sair do MultiCred") { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
        }
    }
}
