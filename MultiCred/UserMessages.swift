import Foundation
import MultiCredCore

/// Portuguese, user-facing text for core errors. The core stays language-neutral.
enum UserMessages {
    static let busy = "Uma troca já está em andamento."
    static let defaultAccountInTestMode = "No modo de teste, o login real só funciona em pastas próprias. A pasta padrão usaria o mesmo item do Keychain do seu login real em ~/.claude."

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as SwitchError: describe(error)
        case let error as ClaudeAccountError: describe(error)
        case let error as JSONStoreError: describe(error)
        case let error as CommandError: error.description
        case let error as PreflightFailure: describe(error)
        case let error as EditorError: describe(error)
        case let error as InstallError: describe(error)
        case let error as FileWriteError: error.description
        case let error as KeychainError: "Keychain: \(error.description)"
        case is GitHubCLIError: "O GitHub CLI respondeu algo inesperado."
        default: String(describing: error)
        }
    }

    static func describe(_ error: EditorError) -> String {
        switch error {
        case let .invalid(issues): describe(issues)
        case .emptySecret: "Cole o valor da chave."
        case let .keychain(reason): "Não consegui gravar no Keychain: \(reason)"
        }
    }

    static func describe(_ error: InstallError) -> String {
        switch error {
        case let .markerMismatch(path): "O bloco do MultiCred em \(path) foi editado à mão e está incompleto. Remova as linhas a partir de \"# >>> MultiCred >>>\" e tente de novo."
        case let .writeFailed(path, reason): "Não consegui alterar \(path): \(reason). Nada foi mudado."
        }
    }

    static func describe(_ issues: [ValidationIssue]) -> String {
        guard let issue = issues.first else { return "Dados inválidos." }
        let text = switch issue {
        case let .emptyField(_, field): "O campo \(fieldName(field)) está vazio."
        case let .controlCharacters(_, field): "O campo \(fieldName(field)) tem quebra de linha ou caractere de controle."
        case .invalidEmail: "E-mail inválido."
        case .invalidGitHubUsername: "Usuário do GitHub inválido (só letras, números e hífen)."
        case .invalidHost: "Servidor do GitHub inválido."
        case let .invalidEnvVar(_, name): "\"\(name)\" não é um nome de variável válido (use LETRAS_MAIUSCULAS e _)."
        case let .reservedEnvVar(_, name): "\(name) é reservada e não pode ser usada para uma chave."
        case let .duplicateEnvVarInProfile(_, name): "O perfil tem duas chaves para \(name)."
        case .invalidClaudeDirectory: "Pasta do Claude inválida (use um caminho absoluto, sem / no fim)."
        case .duplicateClaudeDirectory: "Duas contas Claude antigas usam a mesma pasta."
        case .invalidSSHKeyPath: "Caminho da chave SSH inválido (use caminho absoluto ou começando com ~/)."
        case .missingReference: "O perfil aponta para uma conta que não existe mais."
        case .duplicateID: "Configuração com identificadores repetidos."
        }
        return issues.count > 1 ? "\(text) (+\(issues.count - 1) problema(s))" : text
    }

    private static func fieldName(_ field: String) -> String {
        switch field {
        case "nickname": "apelido"
        case "name": "nome"
        case "email": "e-mail"
        default: field
        }
    }

    static func describe(_ error: SwitchError) -> String {
        switch error {
        case .busy:
            busy
        case .invalidConfiguration:
            "A configuração tem campos inválidos. Revise as contas e perfis."
        case let .stateUnreadable(reason):
            "Não consegui ler o estado atual: \(reason)"
        case let .preflight(failure):
            describe(failure)
        case let .stepFailed(step, reason, rollback):
            switch rollback {
            case .complete:
                "Falhou em \(stepName(step)): \(reason). Nada foi alterado."
            case let .incomplete(failed):
                "Falhou em \(stepName(step)): \(reason). Não consegui desfazer: \(failed.map(stepName).joined(separator: ", ")). Use Verificar."
            }
        }
    }

    static func describe(_ failure: PreflightFailure) -> String {
        switch failure {
        case .profileNotFound: "Esse perfil não existe mais."
        case .claudeAccountNotFound: "Essa conta Claude não existe mais."
        case let .toolMissing(tool): "\(tool.displayName) não foi encontrado neste Mac."
        case let .claudeDirectoryMissing(path): "A pasta do Claude deste perfil não existe: \(path)"
        case let .claudeTokenMissing(nickname): "O token da conta Claude \(nickname) não está no Keychain. Gere outro em Contas › Claude."
        case let .apiKeyMissing(nickname, envVar): "A chave \(nickname) (\(envVar)) não está no Keychain."
        case let .keychainUnavailable(reason): "Não consegui consultar o Keychain: \(reason)"
        }
    }

    static func describe(_ error: ClaudeAccountError) -> String {
        switch error {
        case let .invalidPath(path): "Caminho inválido: \(path). Use um caminho absoluto ou começando com ~/."
        case .invalidToken: "Isso não parece um token do Claude Code. Gere um com \"claude setup-token\" e cole a linha que começa com sk-ant-oat."
        case let .keychain(reason): "Não consegui gravar no Keychain: \(reason)"
        case let .folderMissing(path): "A pasta não existe: \(path)"
        case let .notADirectory(path): "Não é uma pasta: \(path)"
        case let .outsideSandbox(path): "No modo de teste, a pasta precisa ficar dentro do HOME de teste (\(path) está fora)."
        case let .createFailed(reason): "Não consegui criar a pasta: \(reason)"
        case let .invalid(issues): describe(issues)
        }
    }

    static func describe(_ error: JSONStoreError) -> String {
        switch error {
        case let .corrupt(movedTo, _): "A configuração estava ilegível. Guardei uma cópia em \(movedTo) e comecei uma nova."
        case let .unsupportedVersion(found, _): "A configuração foi criada por uma versão mais nova do MultiCred (versão \(found))."
        case let .readFailed(path, reason): "Não consegui ler \(path): \(reason)"
        }
    }

    static func stepName(_ step: SwitchStepKind) -> String {
        switch step {
        case .git: "git"
        case .github: "GitHub CLI"
        case .launchd: "variável do Claude Code (launchd)"
        case .claudeSettings: "co-autoria da Claude (settings.json)"
        case .envFiles: "arquivos de ambiente do shell"
        case .state: "estado do perfil"
        }
    }
}
