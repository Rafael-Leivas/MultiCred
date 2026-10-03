import Foundation
import MultiCredCore

/// Portuguese, user-facing text for core errors. The core stays language-neutral.
enum UserMessages {
    static let busy = "Uma troca já está em andamento."

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as SwitchError: describe(error)
        case let error as ClaudeAccountError: describe(error)
        case let error as JSONStoreError: describe(error)
        case let error as CommandError: error.description
        default: String(describing: error)
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
        case let .claudeDirectoryMissing(path): "A pasta da conta Claude não existe: \(path)"
        case let .apiKeyMissing(nickname, envVar): "A chave \(nickname) (\(envVar)) não está no Keychain."
        case let .keychainUnavailable(reason): "Não consegui consultar o Keychain: \(reason)"
        }
    }

    static func describe(_ error: ClaudeAccountError) -> String {
        switch error {
        case let .invalidPath(path): "Caminho inválido: \(path). Use um caminho absoluto ou começando com ~/."
        case let .folderAlreadyUsed(owner): "Essa pasta já é usada pela conta \(owner)."
        case let .folderMissing(path): "A pasta não existe: \(path)"
        case let .notADirectory(path): "Não é uma pasta: \(path)"
        case let .outsideSandbox(path): "No modo de teste, a pasta precisa ficar dentro do HOME de teste (\(path) está fora)."
        case let .createFailed(reason): "Não consegui criar a pasta: \(reason)"
        case .invalid: "Os dados da conta são inválidos (apelido vazio ou caracteres não permitidos)."
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
        case .envFiles: "arquivos de ambiente do shell"
        case .state: "estado do perfil"
        }
    }
}
