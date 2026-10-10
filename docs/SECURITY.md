# MultiCred — auditoria de segurança (v1)

Data: 2026-10-02. Escopo: execução de comandos, escrita em dotfiles, Keychain, logs e
modo de teste. Feita no lugar do `/cso` automatizado (os binários do gstack não estão instalados
nesta máquina); o checklist abaixo foi aplicado ao código do branch `worktree-v1-plan`.

## Resumo

| Área | Situação |
|---|---|
| Execução de comandos | OK. Sem shell com dados do usuário; argumentos em array; ambiente explícito |
| Arquivos gerados (env.sh, gitconfig, hooks) | OK. Só nomes validados, UUIDs e caminhos com aspas simples |
| Escrita em dotfiles | OK. Bloco marcado, escrita atômica, backup 0600, rollback |
| Keychain | Risco aceito e documentado (ACL com `/usr/bin/security`) |
| Tokens do Claude Code e do gh | OK. Nunca lidos, copiados ou gravados |
| Logs e área de transferência | OK. Códigos de login mascarados; nenhum segredo registrado |
| Modo de teste | OK. Simulação; nada fora do HOME de teste; item de login nunca registrado |

Achado corrigido nesta auditoria: o servidor do GitHub (`host`) aceitava valor começando com `-`,
que o `gh` poderia ler como opção. A validação agora exige letra ou dígito no início (teste
`testGitHubHostAndUserCannotStartWithADash`).

## Execução de comandos

- Todo comando passa por `CommandRunner` (`ProcessRunner`) ou `PseudoTerminalProcess`: caminho
  absoluto do executável, argumentos em array, ambiente montado do zero
  (`SystemEnvironment.baseProcessEnvironment`), nunca herdado do app.
- Os únicos `sh -c` são textos fixos: o `printf` do PATH no `ToolLocator` e os simuladores de
  login do modo de teste. Nenhum recebe dado do usuário.
- Valores do usuário que viram argumentos são validados: usuário do GitHub
  (`^[A-Za-z0-9][A-Za-z0-9-]{0,38}$`), servidor (sem `-` inicial), caminho de conta Claude
  (absoluto e canônico), contas do Keychain (UUID). Nada começa com `-`.
- Ordem de busca de ferramentas: pastas conhecidas (`/opt/homebrew/bin`, `/usr/local/bin`,
  `~/.local/bin`, `/usr/bin`, `/bin`) antes do PATH do shell de login, para um diretório do PATH não
  conseguir se passar por `gh` ou `claude`. `security` e `launchctl` sempre por caminho absoluto.
- Timeouts em todos os comandos; SIGTERM e depois SIGKILL; stdin sem SIGPIPE.

## Arquivos gerados

- `env.sh` / `env.fish`: nome de variável validado (`^[A-Z_][A-Z0-9_]*$`, reservados recusados),
  caminho do Claude entre aspas simples (`ShellQuoting`), conta do Keychain = UUID. Testes passam
  texto hostil (`'`, `$()`, crase, `\`, unicode) por um shell real e conferem que nada executa.
- `gitconfig` incluído: valores entre aspas com escape; caractere de controle vira espaço (teste:
  não dá para injetar uma seção `[core]`). Caminho da chave SSH entre aspas simples dentro de
  `core.sshCommand`.
- Hooks de shell: texto fixo, relativo a `$HOME`.

## Dotfiles

- Só o bloco entre `# >>> MultiCred >>>` e `# <<< MultiCred <<<` é inserido, trocado ou removido.
- Escrita atômica (arquivo temporário com `O_EXCL` no mesmo diretório + `rename`), mantendo as
  permissões. Symlink de dotfile é seguido só até um arquivo regular.
- Backup do original na primeira alteração: `~/Library/Application Support/MultiCred/backups/`
  (pasta 0700, arquivos 0600). Falha no meio da instalação restaura tudo que já foi escrito.
- Bloco editado à mão (marcador sem fim): nada é escrito; o usuário recebe a instrução manual.
- `config.json` e `state.json` 0600; nenhum segredo neles.

## Keychain (risco aceito)

As chaves de API ficam no Keychain (serviço `app.multicred.apikey`, conta = UUID). O item é criado
com uma lista de acesso que confia no próprio app e em `/usr/bin/security`, para o shell exportar a
chave sem diálogo. Consequência: qualquer processo do mesmo usuário que chame
`/usr/bin/security find-generic-password -s app.multicred.apikey -a <uuid> -w` lê a chave sem
pergunta. É o mesmo nível de exposição de exportar a chave no shell. As chaves **não** vão para
`launchctl setenv` (lá ficariam visíveis para todo processo). O app não tem método para ler o
valor de volta: só grava, confere existência e apaga.

Não verificado nesta máquina: se o macOS mostra um diálogo na primeira leitura pelo `security`
(lista de partições do item). Se aparecer, "Sempre permitir" resolve. Coberto no roteiro de teste.

## Tokens das ferramentas

- Claude Code, login da pasta: o app só define/remove `CLAUDE_CONFIG_DIR`, roda
  `claude auth login/status/logout` e lê `oauthAccount.emailAddress` do `.claude.json` (sem token).
  Nunca acessa os itens `Claude Code-credentials*` do Keychain.
- Claude Code, contas Claude (D37, exceção aprovada pelo usuário): o token gerado por
  `claude setup-token` (rodado num pseudo-terminal com uma pasta temporária, apagada no fim) ou
  colado pelo usuário vai direto para o Keychain, no mesmo serviço das chaves de API e com o mesmo
  risco aceito acima. Nunca aparece na tela (a saída do terminal é mascarada), no log nem no
  `config.json`. O shell o exporta como `CLAUDE_CODE_OAUTH_TOKEN` lendo pelo `security`, como as
  chaves; não vai para `launchctl`. Remover a conta ou desinstalar apaga o item.
- gh: `gh auth status --json hosts` (sem `--show-token`), `gh config get … user`,
  `gh auth switch`, `gh auth login --web`. O token fica com o gh.

## Logs, códigos e área de transferência

- `~/Library/Logs/MultiCred/multicred.log` (0600, rotação 1 MB × 3): passos e erros, sem valores.
  Quebras de linha escapadas (não dá para forjar linhas).
- Código colado no login do Claude: enviado ao processo, nunca guardado; aparece como `••••` na
  tela e em "Copiar log".
- Código de uso único do GitHub: copiado para a área de transferência a pedido (é o que o gh
  pede para colar no navegador).

## Modo de teste (builds Debug)

- HOME na pasta temporária; gh e launchctl simulados; git só para leitura, com HOME do sandbox;
  Keychain em memória; logins simulados que recusam escrever fora do HOME de teste.
- Item de login nunca é registrado em modo de teste nem fora de /Applications.
- "Login real" (esquema próprio) recusa a conta padrão, cujo item do Keychain é o mesmo da conta
  real em `~/.claude`.
- Modo real só com `-MultiCredRealSystem YES` (Debug) ou no build Release.

## Fora do escopo da v1

Helper assinado para entregar chaves a apps gráficos; Developer ID e notarização (o script existe,
falta a conta); auto-update.
