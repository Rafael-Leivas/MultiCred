# Spike: isolamento de login por `CLAUDE_CONFIG_DIR` e detecção de login sem ler token

Status: **aguardando autorização** para os comandos contra o sistema real (Fase 1).
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
(preenchido após a autorização)
