# Depois da v1

Itens fora do escopo da v1 (decisão D4 e Hold Scope em docs/PLAN.md). Cada um com o contexto
necessário para retomar.

- **Regras por pasta** (design 07): blocos `includeIf "gitdir:…"` no gitconfig gerado. O `SwitchEngine`
  já gera o arquivo; basta acrescentar os blocos e uma tabela em Ajustes.
- **Proteção de commit** (design 07/06): hook que confere o e-mail antes do commit. Evitar
  `core.hooksPath` global (desliga hooks locais de todos os repos); avaliar hook que encadeia o hook
  local do repositório.
- **Atalho global ⌃⌥P** para abrir o menu (design 02a/07).
- **"Mostrar sessões"** com a conta de cada processo `claude` aberto (design 06/08). Exige descobrir
  o `CLAUDE_CONFIG_DIR` de outros processos; no macOS isso é restrito.
- **"Usado pela última vez"** por perfil (design 01c).
- **Variações de menu 1b/1c** como opção de aparência.
- **Modo `GH_CONFIG_DIR`** como alternativa a `gh auth switch` (ver tabela em docs/PLAN.md §5.4).
- **Chaves de API em apps gráficos** sem `launchctl setenv` em texto puro (helper assinado ou
  integração por app).
- **Auto-update** (Sparkle) e **Homebrew cask**.
- **CLI companheira** `multicred switch <perfil>` para scripts.
- **Exportar/importar** configuração (sem segredos).
- **Troca automática por pasta** (ao entrar num diretório no terminal).
