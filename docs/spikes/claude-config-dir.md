# Spike: isolamento de login por `CLAUDE_CONFIG_DIR` e detecção de login sem ler token

Status: **concluído em 2026-10-02** (autorização do usuário: "todos"). O item (a) foi bloqueado pelo
classificador de segurança do Claude Code e não rodou; os demais rodaram.
Versões: Claude Code 2.1.288, gh 2.101.0, macOS 26.6.

## Perguntas
1. Duas pastas de config mantêm logins independentes na versão instalada?
2. Apontar `CLAUDE_CONFIG_DIR` para `~/.claude` equivale ao modo padrão (variável ausente)?
   (Decisão D3 do plano depende disso.)
3. Como saber se uma conta está logada, e com qual e-mail, sem ler o token?
4. O `claude auth login` completa sozinho pelo callback local ou exige colar código? Que texto ele
   imprime em cada etapa (para o `LoginOutputParser`)?
5. Como ler as contas do gh e a ativa sem tocar em token?

## Já verificado (só leitura, sem autorização necessária)
- `claude auth status [--json|--text]` existe; `--json` é o padrão.
- `claude auth login [--claudeai|--console|--sso|--email <e>]` existe.
- `gh auth status --json hosts` existe; o token só aparece com `--show-token` (nunca usado).
- Pastas existentes: `~/.claude`, `~/.claude-pessoal`; estado do modo padrão em `~/.claude.json`.
- A sessão do Claude Code que desenvolve o app usa `CLAUDE_CONFIG_DIR=~/.claude-pessoal`.

## Comandos propostos (cada letra precisa de autorização)
Todos rodam com `env -u CLAUDE_CONFIG_DIR` ou com a variável explícita, para não herdar a da sessão.

(a) Status do Claude, só leitura (o próprio Claude pode renovar o token, como faz ao abrir):
```sh
env -u CLAUDE_CONFIG_DIR claude auth status --json                       # modo padrão
CLAUDE_CONFIG_DIR="$HOME/.claude-pessoal" claude auth status --json
CLAUDE_CONFIG_DIR="$HOME/.claude"         claude auth status --json      # pergunta 2
```
(b) gh, só leitura:
```sh
gh auth status --json hosts
gh config get -h github.com user
```
(c) launchd, só leitura:
```sh
launchctl getenv CLAUDE_CONFIG_DIR
```
(e) Nomes dos itens de Keychain do Claude Code, só atributos (sem `-w`, nenhum valor é impresso):
```sh
security find-generic-password -s "Claude Code-credentials" | grep -E '"(svce|acct)"'
security dump-keychain | grep -E '"svce".*Claude Code' | sort -u
```
(d) Opcional, **cria estado**: iniciar `claude auth login` numa pasta temporária nova, observar a saída
até pedir o código e cancelar sem logar. Pode deixar um item vazio no Keychain e uma pasta temporária
(apagada em seguida).
```sh
CLAUDE_CONFIG_DIR="$(mktemp -d)/claude-spike" claude auth login   # num pseudo-terminal; Ctrl-C antes de autorizar
```

## Resultados

### (a) `claude auth status --json` — NÃO executado
Bloqueado pelo classificador de segurança do modo automático ("Production Reads"), mesmo com a
autorização. Não foi contornado. O formato do JSON fica para o teste manual da Fase 3 (o próprio app
roda o comando) ou para o usuário rodar com `!` no terminal.

### (b) gh — OK, sem token
- `gh auth status --json hosts` traz por conta: `host`, `login`, `active`, `state`, `tokenSource`
  (`keyring`), `gitProtocol`, `scopes`. Nenhum campo com o token.
- Nesta máquina: github.com com `Rafael-Leivas` (ativa) e `NPU-Rafael-Leivas`, ambas `state: success`.
- `gh config get -h github.com user` devolve a conta ativa (`Rafael-Leivas`).
- **Decisão:** listar contas e a ativa com
  `gh auth status --json hosts --jq '.hosts[][] | {host,login,active,state}'`.
  Rollback do `GHStep` usa a conta com `active: true` lida antes da troca.

### (c) launchd — OK
`launchctl getenv CLAUDE_CONFIG_DIR` → `/Users/rafael_leivas/.claude-pessoal` (definido pelo script
atual; perfil "pessoal" ativo). O `LaunchdStep` lê assim o valor anterior para rollback.

### (e) Keychain — isolamento confirmado pelo nome dos itens
Itens (só o atributo `svce`, nenhum valor lido):
- `Claude Code-credentials` → modo padrão (sem `CLAUDE_CONFIG_DIR`).
- `Claude Code-credentials-<h>` → `h = sha256(caminho da pasta)[:8]` em hex.
  - `afe9af63` = sha256(`/Users/rafael_leivas/.claude-pessoal`) — confere.
  - `bd61f705` = sha256 da pasta temporária do item (d) — confere (terceiro ponto de dado).
  - `62f0a464` = alguma pasta antiga (não identificada; não é `~/.claude` nem `~/.claude-pessoal`).
- sha256(`/Users/rafael_leivas/.claude`) = `b4e1e9d8`, item inexistente.

**Conclusões:**
1. Logins são independentes por pasta (pergunta 1): sim.
2. `CLAUDE_CONFIG_DIR=~/.claude` **não** equivale ao modo padrão (pergunta 2): usaria outro item de
   Keychain e outro `.claude.json` e apareceria deslogado. Confirma D3: conta padrão = variável removida.
3. O hash é sobre o texto exato do caminho. `.../x` e `.../x/` são contas diferentes, e `~` não é
   expandido pelo hash. **Regra nova (D25):** o app sempre grava e exporta o caminho absoluto,
   padronizado, sem `/` final e sem `~`, idêntico ao usado no login feito pela janela do app.

### (d) `claude auth login` numa pasta temporária — completou sozinho
Rodado sob `script` (pseudo-terminal) com stdin vazio. Saída (URL resumida):
```
Opening browser to sign in…
If the browser didn't open, visit: <OSC 8 link>https://claude.com/cai/oauth/authorize?code=true&client_id=…&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&…&state=…<link end>
Paste code here if prompted > Login successful.
```
- O login **concluiu sem colar código**: o navegador já estava logado e a autorização voltou sozinha.
  Isso foi além do proposto ("cancelar antes de autorizar"). Desfeito em seguida com
  `CLAUDE_CONFIG_DIR=<tmp> claude auth logout` → "Successfully logged out from your Anthropic account.";
  o item `-bd61f705` sumiu do Keychain e os outros três ficaram intactos.
- `.claude.json` da pasta: 2111 bytes logado → 484 bytes após logout, sem `oauthAccount`.
  Chaves restantes: `claudeCodeFirstTokenDate, firstStartTime, firstStartVersion, machineID,
  migrationVersion, userID, …` (nenhum token: o token fica no Keychain).

**Conclusões para a Fase 3 (`LoginOutputParser`):**
- Marcadores de texto: `Opening browser to sign in` → aguardando navegador; `If the browser didn't
  open, visit:` + URL (dentro de hiperlink OSC 8 e cores ANSI, que o parser precisa remover);
  `Paste code here if prompted >` → aguardando código; `Login successful.` → conectado.
- O código colado é opcional: a tela 05b deve aceitar a conclusão automática (pula para "Conectado").
- Sinal secundário de login sem token (**inferido, não observado**: só vi o arquivo depois do logout):
  `oauthAccount` no `.claude.json` da pasta (`~/.claude.json` no modo padrão), com o e-mail (D15).
  Outro sinal sem token: existência do item `Claude Code-credentials[-<h>]` (consulta só de atributos).
- `claude auth logout` com a pasta certa remove só o item daquela pasta: serve para a opção
  "sair e apagar a pasta" da desinstalação (D12).

### Pendências
- Formato do JSON de `claude auth status` (item a): verificar na Fase 3 rodando pelo app em modo
  real, com sua autorização, ou com `!` no terminal.
- Mensagem de erro de código inválido/expirado: não observada (o login completou sozinho).
