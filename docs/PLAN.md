# MultiCred v1 — Plano

Status: **aguardando aprovação** (passo 4 do processo). Nenhum código escrito ainda.
Última atualização: 2026-10-02.

Referência visual: `perfis-design/` (é a "./design" do documento original). Fonte de verdade
visual = `perfis-design/screenshots/*.png`; medidas e textos = `perfis-design/telas/*.html`.

---

## 0. Resumo em uma tela

MultiCred é um app de barra de menus (macOS 14+) que troca, com um clique e de forma
transacional, a identidade do git, a conta ativa do `gh`, a conta do Claude Code
(`CLAUDE_CONFIG_DIR`) e as chaves de API de outras IAs (variáveis de ambiente com valor no
Keychain). Substitui os scripts de `~/Perfis` mantendo o mesmo comportamento.

Decisões que fecham a v1 (todas registradas em §2):

| Tema | Decisão |
|---|---|
| Nome | MultiCred em todo texto (o design dizia "Perfis") |
| Pasta do app | `~/Library/Application Support/MultiCred/` para tudo (não `~/.perfis/`) |
| gh | `gh auth switch` global (não `GH_CONFIG_DIR`) — ver §5.4 |
| Conta Claude "padrão" | conta com `configDir = nil` ⇒ `CLAUDE_CONFIG_DIR` removido, igual ao script |
| Pastas de conta Claude | adota as existentes; novas em `~/.claude-<slug>` (editável) |
| Menu | variação **1a** (lista única), via `NSStatusItem` + `NSMenu` |
| Onboarding | **3 passos** (02b) |
| Login Claude | **com terminal** (05b), saída recolhida por padrão, SwiftTerm |
| Shells | zsh, bash e fish; arquivos reais listados na revisão |
| Chaves de API | valor só no Keychain; o hook do shell lê com `/usr/bin/security` só quando o perfil muda; **não** vão para apps gráficos na v1 |
| Desinstalação | remove só blocos marcados; backups ficam como rede de segurança; pastas de conta Claude **não** são apagadas por padrão |
| Legado `~/Perfis` | onboarding detecta, oferece remover as linhas antigas e importa `perfis.conf` |
| Fora da v1 | regras por pasta, proteção de commit, atalho global, "Mostrar sessões" por conta (lista em §11) |
| Distribuição | assinatura ad hoc agora; script de Developer ID + notarização pronto para quando houver conta |

---

## 1. Fatos verificados (sondagens só de leitura, 2026-10-02)

- macOS 26.6, Xcode 27.0, Swift 6.4. git 2.54 (`/usr/bin/git`), gh 2.101 (`/opt/homebrew/bin/gh`),
  Claude Code 2.1.288 (`~/.local/bin/claude`, instalador nativo). Sem XcodeGen, Tuist, fish, codex.
- `claude auth status [--json|--text]` existe ⇒ detectar login sem ler token.
- `claude auth login [--claudeai|--console|--sso|--email]` existe ⇒ o PTY roda isso, não o `claude` interativo.
- `gh auth switch --hostname H --user U` existe. `GH_CONFIG_DIR` muda a pasta inteira de config do gh.
- Nesta máquina: `~/.claude`, `~/.claude-pessoal`, `~/.claude.json` (modo padrão guarda o estado em
  `~/.claude.json`, fora da pasta), shell de login zsh, sem `~/.bashrc`/`~/.bash_profile`.
- **Esta sessão de desenvolvimento roda com `CLAUDE_CONFIG_DIR=~/.claude-pessoal`.** Qualquer passo que
  mexa nessa pasta ou no Keychain do Claude derruba a própria sessão. Reforça a regra de segurança.

A confirmar no spike da Fase 1 (§7): formato do JSON de `claude auth status`, se ele não imprime
segredo, se o login completa sozinho pelo callback local (sem colar código), nome do item de Keychain
por pasta, e `gh auth status --json`.

---

## 2. Registro de decisões

Origem das aprovações: mensagem do usuário de 2026-10-02 — "1 MultiCred, 2 application support,
3 como achar melhor, e o restante como você achar melhor, qualquer coisa depois eu mudo".
Tudo abaixo está **aprovado por delegação** e pode ser revisto.

| ID | Decisão | Por quê |
|---|---|---|
| D1 | Nome MultiCred | Pedido explícito |
| D2 | Config e arquivos gerados em `~/Library/Application Support/MultiCred/` | Pedido explícito; caminho com espaço sempre entre aspas |
| D3 | Contas Claude adotam pastas existentes; conta padrão = sem `CLAUDE_CONFIG_DIR` | Modo padrão usa `~/.claude.json` e outro item de Keychain; apontar a variável para `~/.claude` provavelmente "deslogaria" (spike confirma) |
| D4 | Fora da v1: regras por pasta, proteção de commit (`core.hooksPath` global desliga hooks de todos os repos), atalho global, "Mostrar sessões" por conta, "usado por último" | Hold Scope |
| D5 | Shells: zsh (`~/.zshrc`), bash (`~/.bashrc` + `~/.bash_profile`), fish (`~/.config/fish/conf.d/multicred.fish`) | Requisito; fish sem editar `config.fish` |
| D6 | Comando de instalação do Claude Code exibido: `curl -fsSL https://claude.ai/install.sh \| bash` | Instalador nativo recomendado; é o que esta máquina usa |
| D7 | Menu 1a | Menor risco; nativo; submenu "Trocar só a conta Claude" |
| D8 | Onboarding em 3 passos | Mantém revisão do diff e backup com menos atrito |
| D9 | Login Claude com terminal (SwiftTerm), saída recolhida | Mesmo visual do minimalista + log real no erro |
| D10 | Hook relê chaves no Keychain só quando a "geração" muda; item criado com ACL que inclui `/usr/bin/security` | Prompt rápido; segredo só no Keychain |
| D11 | Chaves de API não vão para `launchctl setenv` na v1 | `launchctl` expõe o valor a todo processo do usuário |
| D12 | Desinstalação remove blocos marcados; backups mantidos; pastas Claude preservadas salvo opção explícita (que roda `claude auth logout` antes) | Não perder edições feitas depois da instalação nem logins |
| D13 | Migração do legado `~/Perfis` no onboarding | Dois hooks brigariam pelo `CLAUDE_CONFIG_DIR` |
| D14 | "Trocar só a conta Claude" é sobreposição até a próxima troca de perfil | Verificar sabe o que esperar |
| D15 | Status/e-mail Claude via `claude auth status --json`; fallback: ler só `oauthAccount.emailAddress` do `.claude.json` | Nenhum token envolvido |
| D16 | Spike usa sistema real só com autorização explícita, item a item (§7) | Regra de segurança |
| D17 | Ad hoc agora; pipeline Developer ID/notarização como script | Sem conta Apple confirmada |
| D18 | Repositório em `~/Documents/git/MultiCred` (pasta renomeada, sem o ponto final) | Feito em 2026-10-02 |
| D19 | macOS 14+ | `@Observable` exige 14; `MenuBarExtra`/`SMAppService` são 13+ |
| D20 | gh via `gh auth switch` | §5.4 |
| D21 | Perfil com campo vazio não troca aquele item (git vazio ⇒ arquivo incluído vazio, vale a identidade do usuário) | Mesmo comportamento do `perfis.conf` |
| D22 | Debug roda em **modo de teste**: HOME temporário + executor que só registra comandos; modo real só com flag explícita | Permite você testar a UI sem tocar no sistema |
| D23 | Projeto: núcleo em pacote Swift local `MultiCredCore` (testes com `swift test`) + app Xcode com `.pbxproj` de pastas sincronizadas | Sem gerador de projeto instalado; núcleo testável sem UI |
| D24 | Menu via `NSStatusItem` + `NSMenu` com cabeçalho SwiftUI em `NSMenuItem.view` (o `MenuBarExtra(.menu)` não aceita o cabeçalho rico do 1a) | Fidelidade ao design |

---

## 3. CEO review (Hold Scope)

### 3.1 Premissas
- **Problema real**: trocar identidade de dev em 4 ferramentas é manual, fácil de esquecer e gera
  commit com e-mail errado ou sessão Claude na conta errada. O script atual já prova a dor (é usado
  hoje) e os limites dele: 2 perfis fixos, `eval` de config, sem rollback, só zsh, painel web local.
- **Não fazer nada**: o script continua funcionando para uma pessoa. Não serve para "outros usuários
  instalarem" (caminhos e nomes fixos, sem desinstalação).
- O plano ataca o problema direto (não um proxy).

### 3.2 O que já existe e é reaproveitado
| Sub-problema | Existente | Reuso |
|---|---|---|
| Arquivo git incluído no fim do `~/.gitconfig` | `trocar-perfil.sh` + `instalar.sh` | Mesma técnica; geração passa a ser em Swift com escape testado |
| Troca de conta gh | `gh auth switch` no script | Igual, com rollback |
| Claude em apps gráficos | `launchctl setenv/unsetenv` | Igual + reaplicação no login |
| Claude em terminais abertos | `claude-env.sh` com `precmd` | Generalizado para bash/fish e por "geração" |
| Instalador idempotente com backup | `instalar.sh` | Mesma ideia, com blocos marcados e manifesto |
| Proteções do painel (token, Host) | `painel.py` | Não se aplica (app nativo, sem servidor) |

### 3.3 Estado dos sonhos (12 meses)
```
  HOJE                         ESTE PLANO (v1)                    IDEAL 12 MESES
  scripts p/ 2 perfis fixos -> app de menu, N contas/perfis,  -> troca automática por pasta,
  só zsh, sem rollback         transacional, zsh/bash/fish,      atalho global, CLI companheira,
  instala com eval             onboarding, Verificar, desinstala  Homebrew cask, auto-update
```
A v1 não bloqueia nada do ideal: o modelo já tem `host` no gh, perfis são dados, e o motor de troca é
uma sequência de passos que aceita novos passos (ex.: `includeIf` por pasta).

### 3.4 Checagem de complexidade (Hold Scope)
O plano passa de 8 arquivos e 2 serviços. É inevitável num app novo; a contenção vem de:
um único motor de troca (perfil inteiro e "só Claude" usam o mesmo), um único executor de comandos,
um único escritor de arquivos atômico, e nenhum servidor ou daemon extra.

### 3.5 Escopo: entra / fica fora
Entra: tudo do documento original, menos o que §11 lista. Fica fora: §11 (vai para `TODOS.md`).

---

## 4. Arquitetura

### 4.1 Módulos
```
┌──────────────────────────── MultiCred.app (SwiftUI + AppKit) ─────────────────────────────┐
│ StatusItemController ─ NSMenu (1a) ─ HeaderView(SwiftUI)                                   │
│ Windows: Onboarding · Contas · EditorPerfil · LoginClaude(SwiftTerm) · Verificar · Ajustes │
│ HUDPanel · Notifier(UNUserNotificationCenter) · LoginItem(SMAppService)                    │
│ AppModel (@Observable, @MainActor) ── chama ──┐                                            │
└───────────────────────────────────────────────┼────────────────────────────────────────────┘
                                                │
┌───────────────────────── MultiCredCore (pacote Swift, sem UI) ────────────────────────────┐
│                                                                                            │
│  Model: GitIdentity GitHubAccount ClaudeAccount APIKeyAccount Profile Settings ActiveState │
│                                                                                            │
│  ConfigStore ──► AtomicFileWriter ◄── Installer / Uninstaller ◄── LegacyMigrator           │
│      │                  ▲                     │                                            │
│      │                  │                     ├─► ShellIntegration (zsh/bash/fish)         │
│      │                  │                     └─► GitIncludeInstaller                      │
│      ▼                  │                                                                  │
│  SwitchEngine (actor) ──┼──► steps: GitConfigStep · GHStep · LaunchdStep · EnvFileStep     │
│      │                  │           · StateCommitStep        (cada um: apply + rollback)   │
│      ▼                  │                                                                  │
│  Verifier ──────────────┘ (lê estado real, compara, gera Fix com comando legível)          │
│                                                                                            │
│  Adapters: GitCLI · GHCLI · ClaudeCLI · Launchctl · ProcessScanner                         │
│      └──────────────► CommandRunner (protocolo)                                            │
│  ToolLocator (PATH explícito + PATH do shell de login)                                     │
│  KeychainStore (protocolo) — só chaves de API                                              │
│  SystemEnvironment { home, appSupport, runner, keychain, clock, fileManager }  ◄─ injeção │
└────────────────────────────────────────────────────────────────────────────────────────────┘
        Real: ProcessRunner, SecItemKeychain       Testes: FakeRunner, FakeKeychain, HOME temporário
        Debug (modo de teste): DryRunRunner (registra, não executa) + HOME em /tmp
```

Regra: **nenhum** tipo do Core lê `NSHomeDirectory()`, `ProcessInfo.environment` ou chama `Process`
diretamente. Tudo vem do `SystemEnvironment`. Um teste de arquitetura faz grep no código-fonte do Core
proibindo esses símbolos fora de `RealEnvironment.swift`.

### 4.2 Arquivos que o app cria ou altera
```
~/Library/Application Support/MultiCred/        (0700)
  config.json          contas, perfis, ajustes (sem segredos)            0600
  state.json           perfil ativo, sobreposição Claude, ativadoEm, geração
  generation           um inteiro; o hook do shell só lê isto a cada prompt
  gitconfig            [user] name/email (+ core.sshCommand)             0644
  env.sh               POSIX (zsh/bash): unset de todas as vars gerenciadas + export das ativas
  env.fish             mesmo conteúdo em sintaxe fish
  shell/hook.zsh  shell/hook.bash  shell/hook.fish
  manifest.json        o que foi instalado (blocos, arquivos, vars launchctl, login item, itens Keychain)
  backups/<AAAA-MM-DD-HHMMSS>/<arquivo original>
~/Library/Logs/MultiCred/multicred.log           (sem segredos; rotação 1 MB × 3)

Fora da pasta (só blocos marcados `# >>> MultiCred >>>` … `# <<< MultiCred <<<`):
  ~/.zshrc                      source do hook.zsh
  ~/.bashrc e ~/.bash_profile   source do hook.bash (o .bash_profile só se o bash for usado)
  ~/.config/fish/conf.d/multicred.fish   arquivo inteiro do app
  arquivo git global (≈ ~/.gitconfig)    [include] path = "~/Library/Application Support/MultiCred/gitconfig"
Estado fora de arquivos:
  launchctl setenv/unsetenv CLAUDE_CONFIG_DIR
  gh: conta ativa (hosts.yml, escrito pelo próprio gh)
  Keychain: itens "app.multicred.apikey" (só chaves de API)
  SMAppService: item de login
NUNCA tocados: tokens do gh e do Claude, conteúdo das pastas ~/.claude*, ~/.config/gh/hosts.yml (só via gh)
```

### 4.3 Conteúdo gerado (exemplos)
`env.sh` (nenhum valor secreto no arquivo; só referências):
```sh
# Generated by MultiCred. Do not edit. generation=42
unset CLAUDE_CONFIG_DIR OPENAI_API_KEY GEMINI_API_KEY
export CLAUDE_CONFIG_DIR='/Users/x/.claude-pessoal'
OPENAI_API_KEY="$(/usr/bin/security find-generic-password -s app.multicred.apikey -a 3F2A…-UUID -w 2>/dev/null)" && export OPENAI_API_KEY || unset OPENAI_API_KEY
```
`hook.zsh` (o bash é análogo via `PROMPT_COMMAND`, compatível com bash 3.2 e com array no 5.1+):
```zsh
_multicred_dir="$HOME/Library/Application Support/MultiCred"
_multicred_apply() {
  local g; g="$(<"$_multicred_dir/generation" 2>/dev/null)" || return 0
  [[ "$g" == "$_multicred_gen" ]] && return 0
  [[ -r "$_multicred_dir/env.sh" ]] && source "$_multicred_dir/env.sh"
  _multicred_gen="$g"
}
_multicred_apply
autoload -Uz add-zsh-hook && add-zsh-hook precmd _multicred_apply
```
Custo por prompt: uma leitura de arquivo de poucos bytes, sem fork no zsh. O `security` só roda
quando a geração muda (e no primeiro prompt de cada shell).

---

## 5. Engenharia

### 5.1 Modelo de dados
```swift
struct GitIdentity   { id: UUID; nickname: String; name: String; email: String; sshKeyPath: String?; color: ProfileColor }
struct GitHubAccount { id: UUID; nickname: String; username: String; host: String = "github.com"; color: ProfileColor }
struct ClaudeAccount { id: UUID; nickname: String; email: String?; color: ProfileColor; configDir: String? } // nil = padrão (~/.claude, sem variável)
struct APIKeyAccount { id: UUID; nickname: String; provider: Provider; envVar: String; color: ProfileColor } // valor no Keychain, account = id
struct Profile       { id: UUID; name: String; color: ProfileColor; icon: ProfileIcon; gitId: UUID?; githubId: UUID?; claudeId: UUID?; apiKeyIds: [UUID] }
struct ActiveState   { profileId: UUID?; claudeOverrideId: UUID?; activatedAt: Date; generation: Int }
struct Config        { version: Int = 1; git, github, claude, apiKeys: [..]; profiles: [Profile]; settings: Settings }
```
Validação (no `ConfigStore`, rejeita com mensagem): sem `\n`/`\r`/NUL em nenhum texto; e-mail com `@`;
`envVar` casa `^[A-Z_][A-Z0-9_]*$` e não é `PATH`/`HOME`/`SHELL`/`CLAUDE_CONFIG_DIR`; dois `apiKeyIds`
do mesmo perfil não podem ter a mesma `envVar`; `configDir` absoluto ou `~/…`, sem `..`; duas contas
Claude não podem apontar para a mesma pasta; usuário gh casa `^[A-Za-z0-9-]+$`; ordem dos perfis = ⌘1…⌘9.

### 5.2 Motor de troca transacional
```
switch(to: profile) / switchClaudeOnly(to: account)
  │
  ├─ 0. Preflight (nada muda ainda)
  │     valida referências · ToolLocator acha git/gh/claude necessários
  │     gh: conta existe em `gh auth status` · claude: pasta existe
  │     chaves: itens existem no Keychain (só atributos, sem ler valor)
  │     falha ⇒ erro "Preflight: <motivo>", nada a desfazer
  │
  ├─ 1. GitConfigStep     salva conteúdo atual → grava gitconfig (atômico)   ↩ regrava o antigo
  ├─ 2. GHStep            lê conta ativa por host → gh auth switch            ↩ gh auth switch p/ a antiga
  ├─ 3. LaunchdStep       launchctl getenv → setenv/unsetenv                  ↩ restaura valor antigo
  ├─ 4. EnvFileStep       salva env.sh/env.fish → grava novos (atômico)       ↩ regrava os antigos
  └─ 5. StateCommitStep   grava state.json, depois `generation` += 1  ◄── PONTO DE COMMIT
                          (os shells só trocam aqui)
  Falha no passo k ⇒ rollback de k-1…1 em ordem reversa
     rollback ok      ⇒ "Falhou em <etapa>: <motivo>. Nada foi alterado."
     rollback falhou  ⇒ "Falhou em <etapa>; não consegui desfazer <etapas>". Estado = inconsistente,
                        menu mostra laranja + Corrigir, log detalhado.
```
`switchClaudeOnly` usa os passos 3, 4 e 5 (com `claudeOverrideId`). O `SwitchEngine` é um `actor`:
uma troca por vez. Um segundo pedido durante a troca é rejeitado ("Troca em andamento") e a UI
desabilita os itens. Timeout por comando: 15 s (`gh` pode travar em rede/keychain).

Máquina de estados do app:
```
 unconfigured ──onboarding ok──► idle(consistent) ◄──────────────┐
                                    │  switch                     │ ok
                                    ▼                             │
                                 switching ──falha+rollback ok────┤ (mantém perfil anterior)
                                    │
                                    └─falha+rollback falhou──► idle(inconsistent) ──Corrigir/Verificar──► idle(consistent)
 Inválidas: switching→switching (actor rejeita); unconfigured→switching (UI não oferece; engine rejeita sem config)
```

### 5.3 Claude Code
- Pasta por conta. Conta padrão (`configDir == nil`) ⇒ `launchctl unsetenv` + `unset` no `env.sh`.
- Status: `CLAUDE_CONFIG_DIR=<dir> claude auth status --json` (sem a variável para a padrão).
  Cache por conta (TTL 5 min), atualizado em segundo plano ao abrir Contas/Verificar e após login.
  O menu nunca espera por isso.
- Login: `LocalProcess` do SwiftTerm roda `claude auth login` com env mínimo explícito
  (`HOME`, `PATH` resolvido, `TERM=xterm-256color`, `LANG`, `CLAUDE_CONFIG_DIR` ou ausente).
  Estados derivados da saída por um `LoginOutputParser` (padrões num só lugar, testados com
  transcrições reais do spike) e confirmados por `auth status` ao fim:
  ```
  starting ─URL/abrindo navegador─► waitingBrowser ─prompt de código─► waitingCode ─Conectar─► connecting
      │                                   │                                                  │
      │                                   └─callback local completou sozinho────────────────►├─ status ok ─► connected
      └─ processo saiu ≠0 / timeout 10 min / padrão de erro ─────────────────────────────────┴─────────────► error
  ```
  O código colado vai direto para o PTY (`send(code + "\r")`), o campo é limpo, e "Copiar log"
  substitui o código por `••••` antes de copiar. Nada é gravado.
- Aviso de sessões abertas: `ProcessScanner` conta processos `claude` do usuário (sysctl, sem ler
  ambiente de outros processos). Se N > 0 após a troca, o HUD vira a variante com aviso:
  "N sessões do Claude Code já abertas continuam na conta anterior. Reinicie-as para usar X."
  Sem botão "Mostrar sessões" (§11).

### 5.4 Decisão: `gh auth switch` × `GH_CONFIG_DIR`
| Critério | `gh auth switch` (escolhido) | `GH_CONFIG_DIR` por perfil |
|---|---|---|
| git via HTTPS (`gh auth git-credential`) | segue a conta ativa global, sem variável | precisa da variável em todo processo que roda git (IDE incluída) |
| Apps gráficos | funciona na hora | só após reabrir, e só com `launchctl setenv` |
| Login | uma vez por conta, todas no mesmo hosts.yml | um `gh auth login` por pasta |
| Comportamento atual | igual ao script | muda |
| Ponto fraco | estado global; outra ferramenta pode trocar | estado espalhado; extensões/config duplicadas |
O ponto fraco do escolhido é coberto pelo Verificar (conta ativa ≠ esperada ⇒ "Corrigir").

### 5.5 Git
- Arquivo global alvo: `~/.gitconfig` se existir; senão `$XDG_CONFIG_HOME/git/config` ou
  `~/.config/git/config` se existir; senão cria `~/.gitconfig`. Se o alvo é symlink (dotfiles com
  stow/chezmoi), edita o destino real e avisa no onboarding.
- O bloco `[include]` precisa ser o **último** que define `user.*`. O Verificar usa
  `git config --global --show-origin --get-all user.email` e aponta arquivo e linha quando algo
  depois do include sobrescreve (é o caso do design 06).
- `core.sshCommand = ssh -i '<path>' -o IdentitiesOnly=yes`, com aspas simples escapadas.
- Gerador próprio com escape de `"` e `\`; testes leem o resultado com o git real em ambiente
  isolado (`HOME` temporário, `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=<tmp>`).

### 5.6 PATH e execução de comandos
- `CommandRunner.run(_ executable: URL, _ args: [String], env: [String: String], stdin: Data?, timeout:)`.
  Nunca há string de shell; sem `sh -c`. Ambiente sempre explícito (não herda o do app).
- `ToolLocator`: procura em `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `/usr/bin`, mais o
  PATH do shell de login (`$SHELL -l -c 'printf "__MC__%s__MC__" "$PATH"'`, timeout 5 s, só o trecho
  entre marcadores). `security` e `launchctl` sempre por caminho absoluto do sistema. Cache, refeito
  em "Verificar de novo" e no onboarding.

### 5.7 Instalador, migração e desinstalação
- Idempotente: procura o bloco marcado; se existe e está igual, não faz nada; se existe e difere,
  substitui só o bloco. Antes da primeira alteração de cada arquivo numa execução, backup em
  `backups/<data>/`. Escrita atômica (temp no mesmo diretório + rename), preservando permissões.
- Legado: detecta `Perfis/claude-env.sh` em rc e `Perfis/git-atual.gitconfig` em include. Oferece
  remover essas linhas (backup antes) e importa `~/Perfis/perfis.conf` **sem executar** (parser de
  `CHAVE="valor"`, expande só `$HOME` e `~`).
- Desinstalar (com confirmação que lista tudo): remove blocos marcados e o `conf.d` do fish, remove o
  include, `launchctl unsetenv` das vars que o manifesto registrou, desregistra o item de login, apaga
  os itens de Keychain do app, apaga a pasta de suporte **exceto** `backups/` (movida para
  `~/Library/Application Support/MultiCred-backups-<data>/`). Opção marcada a parte: "Também sair e
  apagar as pastas de conta Claude criadas pelo MultiCred" (roda `claude auth logout` em cada uma
  antes). Contas do gh ficam como estão.

### 5.8 Item de login e reaplicação
`SMAppService.mainApp.register()`. Ao iniciar: carrega config e estado; se houver perfil ativo,
roda o mesmo `SwitchEngine` com o perfil ativo (idempotente). Falha ⇒ estado inconsistente e
notificação, sem loop de tentativas.

### 5.9 Mapa de erros e resgate
```
CODEPATH                    | O QUE PODE DAR ERRADO                        | ERRO
----------------------------|----------------------------------------------|---------------------------
ConfigStore.load            | arquivo ausente / JSON corrompido / versão nova | .notFound / .corrupt / .unsupportedVersion
ConfigStore.save            | disco cheio, permissão                        | .writeFailed(path, errno)
ToolLocator.locate          | ferramenta ausente; shell de login trava       | .toolMissing(name) / .shellTimeout
CommandRunner.run           | não executável, timeout, saída ≠ 0            | .launchFailed / .timeout / .nonZero(code, stderr)
GitConfigStep               | escrita falha                                  | .writeFailed
GHStep                      | conta não logada no gh; keychain do gh trava   | .ghAccountNotLoggedIn(user) / .timeout
LaunchdStep                 | launchctl falha                                | .nonZero
EnvFileStep / StateCommit   | escrita falha                                  | .writeFailed
KeychainStore               | item ausente; acesso negado; usuário cancela   | .itemNotFound / .accessDenied / .userCanceled
ClaudeCLI.authStatus        | claude ausente; JSON inesperado; timeout       | .toolMissing / .unexpectedOutput / .timeout
LoginSession                | processo morre; código inválido; 10 min        | .exited(code) / .rejected / .timeout
Installer                   | rc é symlink quebrado; arquivo não-UTF8        | .unsafeTarget(path) / .encoding(path)
Uninstaller                 | bloco editado à mão (marcador sem fim)         | .markerMismatch(path)

ERRO                      | RESGATADO | AÇÃO                                     | USUÁRIO VÊ
--------------------------|-----------|------------------------------------------|----------------------------------------------
.corrupt                  | S | renomeia p/ config.json.corrupt-<ts>, abre onboarding | "Configuração ilegível, guardei uma cópia"
.unsupportedVersion       | S | não sobrescreve; modo só leitura          | "Config de versão mais nova do MultiCred"
.toolMissing              | S | preflight bloqueia o passo / onboarding   | "gh não encontrado" + comando de instalação
.shellTimeout             | S | usa só caminhos fixos; registra           | nada (log); Ajustes>Avançado mostra
.ghAccountNotLoggedIn     | S | preflight falha antes de mudar            | "Entre com X no gh: gh auth login" + Copiar
.timeout / .nonZero       | S | rollback dos passos anteriores            | "Falhou em <etapa>: <stderr resumido>"
rollback falhou           | S | estado inconsistente + log                | laranja no menu, "Corrigir"
.itemNotFound (Keychain)  | S | preflight falha                           | "Chave X sumiu do Keychain" + "Editar conta"
.accessDenied/.userCanceled| S| aborta operação                           | mensagem; nada alterado
.unexpectedOutput (claude)| S | status = desconhecido (não "desconectada")| "Status indisponível" + Ver detalhes
LoginSession.*            | S | estado error, log com código mascarado    | tela de erro 05b
.unsafeTarget/.encoding   | S | não altera aquele arquivo                 | instrução manual com o texto exato da linha
.markerMismatch           | S | não remove; mostra instrução manual        | "Remova à mão o bloco em <arquivo>"
```
Nenhum `catch` genérico silencioso: todo erro vira um caso tipado acima, com log e mensagem.

### 5.10 Segurança (modelo de ameaças resumido; /cso aprofunda antes da v1)
| Ameaça | Prob. | Impacto | Mitigação |
|---|---|---|---|
| Injeção em comando via nome/e-mail/caminho | M | A | sem shell; args em array; validação §5.1 |
| Injeção no `env.sh`/`gitconfig` gerado (texto do usuário vira código no shell) | M | A | só caminhos e UUIDs entram no `env.sh`, com aspas simples escapadas; rejeita controle/newline; testes de fuzz com `'`, `$()`, `` ` ``, `\`, unicode |
| Segredo vazando para arquivo/log | M | A | valor nunca sai do Keychain exceto no shell do usuário; logger com redação; log de login mascara o código |
| Outro processo lê chave via `launchctl` | — | A | chaves não vão para launchctl (D11) |
| Symlink no lugar de rc/gitconfig apontando para fora | B | M | resolve, mostra o destino real, backup do destino; recusa se o destino não é arquivo regular |
| `PATH` do shell de login aponta para binário malicioso chamado `gh` | B | A | prioridade: caminhos fixos conhecidos antes do PATH; Ajustes>Avançado mostra o caminho de cada ferramenta |
| Arquivos do app legíveis por outros usuários | B | M | pasta 0700, config/state 0600 |
| ACL do item de Keychain permitindo `/usr/bin/security` | — | M | qualquer processo que chame `security` como o usuário pode pedir o item; é o preço de exportar no shell. Documentar no README; alternativa futura: helper assinado |

### 5.11 Desempenho
- Abrir o menu: só leitura do `AppModel` em memória (< 16 ms). Status Claude/gh vem de cache.
- Troca: ~5 processos (`gh` ~150 ms, `launchctl` ~10 ms). Meta < 1 s. HUD aparece no fim.
- Hook do shell: leitura de um arquivo por prompt; `security` só quando muda a geração.
- `claude auth status` (node, ~0,5–1 s) nunca no caminho do menu.

### 5.12 Observabilidade
`os.Logger` (subsystem `app.multicred`) + arquivo em `~/Library/Logs/MultiCred/`. Cada troca registra
id da transação, perfil, passos, duração, resultado e rollback, sem valores sensíveis. Ajustes >
Avançado: caminhos das ferramentas, "Abrir pasta de logs", "Copiar diagnóstico" (versões,
caminhos, últimas 50 linhas de log).

### 5.13 Plano de testes (XCTest, sempre com HOME temporário)
```
ITEM                                   | TIPO        | FELIZ                     | FALHA                        | BORDA
---------------------------------------|-------------|---------------------------|------------------------------|-------------------------------
ConfigStore                            | unit        | round-trip JSON           | corrompido → .corrupt+cópia  | versão futura; texto com \n rejeitado
GitConfigRenderer                      | unit+git real isolado | name/email/ssh lidos pelo git | —                  | aspas, \, unicode, sem ssh
EnvFileRenderer (sh e fish)            | unit+shell real | exports corretos      | —                            | var de outro perfil é unset; aspas no caminho
SwitchEngine                           | unit (FakeRunner) | ordem dos passos, geração +1 | falha em cada passo k ⇒ rollback k-1…1 | rollback que falha ⇒ inconsistente; 2 trocas simultâneas
SwitchEngine só Claude                 | unit        | só passos 3–5             | launchctl falha              | override some na próxima troca de perfil
Preflight                              | unit        | ok                        | conta gh ausente; pasta Claude ausente; item Keychain ausente | ferramenta ausente
Hook zsh/bash/fish                     | integração (/bin/zsh -f, bash --norc; fish se instalado) | troca após bump de geração | env.sh ausente | bash 3.2 PROMPT_COMMAND string e array; PROMPT_COMMAND pré-existente preservado
Installer                              | unit        | adiciona blocos + backup  | rc symlink quebrado          | rodar 2× = mesmo arquivo (idempotência byte a byte); rc sem \n final; XDG gitconfig
Uninstaller                            | unit        | arquivo volta ao original | marcador sem fim             | edições do usuário fora do bloco preservadas
LegacyMigrator                         | unit        | importa perfis.conf       | arquivo malformado           | $HOME no valor; nunca executa
ToolLocator                            | unit        | acha em ~/.local/bin      | shell trava (timeout)        | PATH com espaços
ClaudeCLI.authStatus parser            | unit (fixtures do spike) | logado/deslogado | JSON inesperado ⇒ desconhecido | —
LoginOutputParser                      | unit (transcrições do spike) | sequência de estados | código inválido | callback completa sem código
Verifier                               | unit        | 7/7 ok                    | e-mail sobrescrito depois do include (arquivo+linha) | gh trocado por fora; hook removido do rc
Segurança                              | unit        | —                         | fuzz de nomes no env.sh/gitconfig não executa nada | —
Guarda de arquitetura                  | unit        | Core não usa NSHomeDirectory/Process/ProcessInfo.environment fora de RealEnvironment | | |
```
Teste "2h da manhã de sexta": troca A→B→A com falha injetada no `gh` no meio, conferindo que o
`gitconfig`, o `env.sh`, o `launchctl` (fake) e a geração voltam exatamente ao estado de A.
Nenhum teste chama `RealEnvironment`; um `setUp` base falha se `HOME` do ambiente do teste for o
HOME real.

### 5.14 Distribuição
`scripts/release.sh`: `xcodebuild archive` (Release, hardened runtime), `codesign` Developer ID,
`notarytool submit --wait`, `stapler staple`, zip/DMG. Sem credenciais, gera build ad hoc e avisa.
Sem entitlements especiais (sem sandbox). Atualização automática fica para depois (§11).

---

## 6. Design review (plano × `perfis-design/`)

Nota inicial do plano contra o design: 6/10 (faltavam escolhas de variação, estados vazios e o
tratamento das funções cortadas). Depois das decisões abaixo: 9/10.

| Tela | Segue o design | Ajustes no plano (e por quê) |
|---|---|---|
| Ícone na barra | quadrado arredondado com cor + letra/símbolo do perfil | `NSImage` desenhado (não template). Sem perfil: "M" cinza. Inconsistente: ponto laranja no canto (o design não mostra; mínimo para não esconder erro) |
| 1a Menu | cabeçalho (avatar, "Ativo desde", pílula, 3 linhas git/gh/Claude), faixa laranja com "Corrigir", perfis ⌘1…, submenu Claude, Verificar ⌘R, Contas, Ajustes ⌘, Sair ⌘Q | "Sair do MultiCred". Cabeçalho é SwiftUI dentro de `NSMenuItem.view`. Perfil cuja conta Claude precisa entrar mostra o aviso e, ao clicar, oferece "Entrar…" antes de trocar |
| 1a submenu Claude | lista de contas, "do perfil", "Entrar…", "Adicionar conta Claude…", rodapé de aviso | — |
| Estado vazio | (não desenhado) | Sem config: menu com "Configurar MultiCred…" e Sair |
| 02b Onboarding | Preparar → Perfis → Aplicar | Passo 1 mostra o comando nativo do Claude Code (D6). Passo 1 ganha cartão "Encontramos a versão antiga (~/Perfis)" quando houver. Passo 3 lista os arquivos reais (zsh/bash/fish marcáveis) em vez de "só 2 linhas em 2 arquivos"; backup em Application Support |
| 03 Contas | barra lateral Git/GitHub/Claude/Chaves com contagem e alerta, perfis, tabela, "Adicionar conta", nota de tokens, menu de contexto | Texto da nota cita `CLAUDE_CONFIG_DIR` e a pasta real de cada conta; conta padrão aparece como `~/.claude (padrão)` |
| 04 Editor | nome, 8 cores, ícone letra/símbolo, prévia na barra, composição | Uma linha por provedor de chave de API cadastrado (OpenAI, Gemini, …), não só os dois fixos |
| 05b Login | estados aguardando código, conectado, erro; Copiar log | Acrescenta "aguardando navegador" do 05a; se o callback completar sozinho, pula direto para "Conectado" |
| 06 Verificar | checklist com esperado/encontrado/origem, Corrigir com comando, Corrigir tudo, Verificar de novo | Sai a linha "Hook de proteção de commit" (D4). Entram: include é o último, cada shell integrado, chaves no Keychain, legado conflitante. A linha de sessões vira informativa (contagem), sem "Mostrar". Corrige o defeito de layout do screenshot (rodapé sobreposto à última linha): rodapé fixo fora da lista rolável |
| 07 Ajustes | Geral (abrir ao iniciar, ao trocar mostrar), zona vermelha de desinstalar | Saem atalho global, regras por pasta e proteção de commits (D4). Aba Avançado: shells integrados, caminhos das ferramentas, logs. Aba Contas abre a janela Contas |
| 08 HUD | HUD 1,5 s + notificação; variante com aviso que fica até fechar | Variante com aviso sem "Mostrar sessões" (só "Ok"). "Ao trocar, mostrar": HUD breve / só notificação / nada |
| Tokens | cores de perfil exatas; resto com cores semânticas do sistema | 8 cores de perfil exatas do `tokens.json`; raios do `tokens.json`; claro/escuro automáticos |

Acessibilidade: cada avatar colorido tem rótulo VoiceOver ("Perfil Trabalho, ativo"); status nunca só
por cor (ícone + texto); todos os controles alcançáveis por teclado; contraste da letra branca sobre as
8 cores verificado (a "laranja" #D9770B fica no limite: usar peso semibold no texto do ícone).

Fluxo do usuário:
```
1º uso: abrir app ─► Onboarding(Preparar ─► Perfis ─► Aplicar) ─► menu com perfil inicial ativo
Dia a dia: clique no ícone ─► 1a ─┬─ perfil ⌘N ─► troca ─► HUD/notificação ─► ícone muda de cor
                                  ├─ Trocar só Claude ▸ conta ─► troca parcial ─► HUD
                                  ├─ "Inconsistente" ─► Corrigir (inline) | Verificar ⌘R ─► Corrigir item/tudo
                                  ├─ Contas… ─► Adicionar / Entrar… ─► Login 05b ─► Conectado ─► [Ativar]
                                  └─ Ajustes… ─► Geral / Avançado / Desinstalar…
```

---

## 7. Segurança durante o desenvolvimento

1. Testes só com `SystemEnvironment` de teste (HOME temporário, `FakeRunner`, `FakeKeychain`).
   Testes de integração usam `/usr/bin/git`, `/bin/zsh -f` e `bash --norc --noprofile` apontando para o
   HOME temporário, com `GIT_CONFIG_NOSYSTEM=1`. Nada de `gh`, `claude`, `launchctl` ou `security`
   reais nos testes.
2. O app em Debug abre em **modo de teste** (D22): HOME em `/tmp/multicred-sandbox`, `DryRunRunner`
   que registra os comandos numa janela "Comandos que seriam executados", `FakeKeychain`. Faixa
   "MODO DE TESTE" visível. Modo real só com `-MultiCredRealSystem YES`, que eu não uso sem sua
   autorização.
3. Spike da Fase 1 — vou pedir autorização separada para cada item:
   - (a) `claude auth status --json` com `CLAUDE_CONFIG_DIR` em `~/.claude-pessoal` e sem a variável.
     Esperado: só leitura (pode renovar token sozinho, como faz ao abrir).
   - (b) `gh auth status --json …` e `gh config get -h github.com user`. Só leitura.
   - (c) `launchctl getenv CLAUDE_CONFIG_DIR`. Só leitura.
   - (d) `claude auth login` numa pasta temporária nova, até a tela de código, cancelando sem
     logar. Pode criar um item vazio no Keychain. Opcional.
4. Edições restritas à pasta do projeto (worktree). O `/freeze` não pôde ser ativado neste ambiente
   (o harness bloqueou o script dele); o isolamento do worktree cumpre o papel.

---

## 8. Fases

Cada fase termina com: testes passando, `/review`, correções, commit, atualização desta seção e
PARE com resumo + roteiro de teste manual.

| Fase | Entrega | Arquivos principais (estimativa) | Verificação |
|---|---|---|---|
| 1 Fundação e spikes | `MultiCred.xcodeproj` + pacote `MultiCredCore`; `SystemEnvironment`, `CommandRunner` (real, fake, dry-run), `ToolLocator`, `KeychainStore` (SecItem + fake), `ConfigStore`, `AtomicFileWriter`, logger; `docs/spikes/claude-config-dir.md` | ~20 | `swift test`; build do app; spike documentado |
| 2 Modelo e motor | modelos, validação, renderers (gitconfig, env.sh, env.fish, hooks), steps, `SwitchEngine`, `state.json`/`generation` | ~15 | testes de motor, rollback, hooks reais isolados |
| 3 Contas Claude | `ClaudeCLI`, cache de status, `LoginSession` (SwiftTerm), `LoginOutputParser`, janela 05b, troca só Claude | ~10 | parser com fixtures; teste manual no modo de teste |
| 4 Interface | ícone + menu 1a, Contas 03, Editor 04, HUD/notificação 08 | ~15 | roteiro manual claro/escuro |
| 5 Onboarding e instalação | onboarding 02b, detecção + sugestões, `Installer`, `LegacyMigrator`, `Uninstaller`, item de login, Ajustes 07 | ~12 | idempotência e desinstalação em HOME temporário |
| 6 Verificar | `Verifier`, Fix com comando visível, tela 06, pílula/faixa do menu | ~6 | testes do verifier; roteiro manual |
| Fechamento | `/cso`, `/document-release` (README: instalação, o que altera, o que nunca toca), `scripts/release.sh` | — | auditoria sem achados críticos abertos |

Progresso:
- [x] Passo 1 /office-hours — premissas e perguntas respondidas (2026-10-02)
- [x] Passo 2 /plan-ceo-review (Hold Scope)
- [x] Passo 3 /plan-eng-review
- [x] Passo 4 /plan-design-review
- [ ] Aprovação do plano
- [ ] Fase 1 · [ ] Fase 2 · [ ] Fase 3 · [ ] Fase 4 · [ ] Fase 5 · [ ] Fase 6 · [ ] /cso · [ ] /document-release

### Sequência da Fase 1 (o que o implementador precisa saber)
- Hora 1: criar pacote `MultiCredCore` (swift-tools 6.0, macOS 14) e o `.xcodeproj` com pastas
  sincronizadas referenciando o pacote local; scheme Debug com argumentos do modo de teste.
- Horas 2–3: `CommandRunner` com timeout e captura de stdout/stderr sem deadlock (ler pipes em paralelo).
- Horas 4–5: `ToolLocator` com o shell de login: cuidado com rc que imprime texto (por isso os marcadores).
- Hora 6+: `KeychainStore` real com `SecAccess` incluindo `/usr/bin/security` (API legada; só no
  keychain de arquivo). Teste real fica atrás de `MULTICRED_ALLOW_REAL_KEYCHAIN=1`, que só rodo
  com sua autorização.

---

## 9. Registro de modos de falha
```
CODEPATH            | FALHA                               | RESGATADO | TESTE | USUÁRIO VÊ                 | LOG
--------------------|-------------------------------------|-----------|-------|----------------------------|----
SwitchEngine        | gh falha no meio                    | S         | S     | "Falhou em GitHub CLI…"    | S
SwitchEngine        | rollback falha                      | S         | S     | laranja + Corrigir         | S
Hook do shell       | env.sh ausente/ilegível             | S (no-op) | S     | nada; Verificar acusa      | —
Hook do shell       | security pede permissão/negado      | S (unset) | M     | var vazia; Verificar acusa | —
Login Claude        | código expirado                     | S         | S     | estado Erro 05b            | S
Status Claude       | formato do CLI mudou                | S         | S     | "Status indisponível"      | S
Installer           | rc gerenciado por chezmoi sobrescreve depois | S (detecta) | S | Verificar: "~/.zshrc não carrega o MultiCred" | S
Reaplicar no login  | gh/keychain travado no boot         | S (timeout) | S   | notificação + laranja      | S
launchctl setenv    | app gráfico aberto antes da troca   | n/a       | —     | texto fixo no menu/HUD: vale para apps reabertos | —
```
(M = teste manual.) Nenhuma linha silenciosa sem teste.

---

## 10. Implementação — tarefas
Cada fase de §8 é uma tarefa com verificação própria. Tarefas finas são criadas no início de cada fase.

## 11. Depois da v1 (não entra agora)
Ver `TODOS.md`. Resumo: regras por pasta (`includeIf`), proteção de commit, atalho global ⌃⌥P,
"Mostrar sessões" com a conta de cada processo, "usado por último", variações de menu 1b/1c, modo
`GH_CONFIG_DIR`, chaves de API para apps gráficos com helper seguro, auto-update (Sparkle), Homebrew
cask, CLI companheira `multicred switch`, exportar/importar config, troca automática por pasta.

---

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 1 | CLEAR (não persistido no log do gstack) | mode: HOLD_SCOPE, 0 critical gaps; 5 itens do design movidos para depois da v1 |
| Outside Review | codex (indisponível) | Independent 2nd opinion | 0 | unavailable | codex não instalado; segunda opinião por subagente não rodada; no completed external review |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 1 | CLEAR (não persistido no log do gstack) | 14 issues resolvidos no plano, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 1 | CLEAR (não persistido no log do gstack) | score: 6/10 → 9/10, 12 decisions |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | não aplicável |

- **OUTSIDE COVERAGE:** codex, fase plan-review, indisponível (CLI não instalado); nenhuma revisão externa concluída.
- **VERDICT:** CEO + ENG + DESIGN CLEARED — pronto para implementar após aprovação do usuário.
- Observação: os binários de log do gstack (`~/.claude/skills/gstack/bin`) não existem nesta instalação; o histórico de reviews não foi gravado.

NO UNRESOLVED DECISIONS
