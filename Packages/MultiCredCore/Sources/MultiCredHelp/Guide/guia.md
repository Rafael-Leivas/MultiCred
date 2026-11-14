# Guia do MultiCred
versão: 0.1.0

> Manutenção: ao mudar uma tela, ajuste, arquivo gerado, comando ou check do MultiCred, pergunte ao usuário: "Deseja atualizar as tools do MCP (e o guia) para refletir esta mudança?"

## Sobre

O MultiCred é um app de barra de menus para macOS 14+ que troca, com um clique, tudo o que muda entre os seus perfis (por exemplo "Pessoal" e "Trabalho"): a identidade do git (nome e e-mail dos commits), a conta ativa do GitHub CLI (`gh`), a conta do Claude Code (variável `CLAUDE_CONFIG_DIR`) e as chaves de API de outras IAs (variáveis de ambiente com o valor guardado no Keychain).

Um perfil junta essas quatro coisas. Clicar no perfil no menu aplica tudo de uma vez, de forma transacional: se algum passo falha, o app volta ao estado anterior. Terminais já abertos também trocam a cada prompt, nos shells ativados em Ajustes (zsh, bash e fish).

O app não tem telemetria nem chamadas de rede próprias. O código é aberto (licença MIT).

### O que o app altera

- Um bloco marcado (`# >>> MultiCred >>>`) no fim de `~/.zshrc`, de `~/.bash_profile` e `~/.bashrc` (se o bash estiver ativo) e do gitconfig global (um `[include]` do arquivo gerado).
- `~/.config/fish/conf.d/multicred.fish` (se o fish estiver ativo).
- `launchctl setenv/unsetenv CLAUDE_CONFIG_DIR`, para apps gráficos abertos depois da troca.
- A conta ativa do `gh` (`gh auth switch`).
- Itens `app.multicred.apikey` no Keychain (só os valores das chaves de API).
- A pasta `~/Library/Application Support/MultiCred/` (config.json, state.json, gitconfig, env.sh, env.fish, a pasta shell, backups) e `~/Library/Logs/MultiCred/`. Item de login (opcional).

### O que o app nunca toca

Tokens do Claude Code e do gh, o conteúdo das pastas `~/.claude*`, o `hosts.yml` do gh (só mexe via o comando `gh`) e qualquer linha dos seus arquivos fora do bloco do MultiCred.

### Onde ficam as telas

- Menu da barra: lista de perfis (clique para ativar), "Criar um perfil…", "Trocar só a conta Claude", "Verificar…" (⌘R), "Contas…" e "Ajustes…" (⌘,).
- Janela única com barra lateral: perfis, Git, GitHub, Claude, Chaves de API, Verificar e Ajustes. Subtelas abrem na mesma janela, com botão Voltar.

## Tarefas

### criar-perfil · Criar um perfil
palavras-chave: novo perfil, criar perfil, perfil novo, montar perfil, adicionar perfil

1. No menu da barra, clique em "Criar um perfil…" (ou na janela, em Novo perfil).
2. Dê um nome e uma cor.
3. Escolha a identidade git, a conta GitHub, a pasta/conta Claude e as chaves de API do perfil. Se ainda não existem, crie antes em Git, GitHub, Claude e Chaves de API.
4. Salve e use "Ativar este perfil". O perfil só muda o Mac quando é ativado.

### adicionar-conta-claude · Adicionar uma conta Claude
palavras-chave: conta claude, login claude, entrar no claude, segunda conta claude, nova conta claude, claude code conta

1. Menu › "Trocar só a conta Claude" › "Adicionar conta Claude…" (ou Claude › Adicionar conta).
2. O MultiCred abre o login do Claude Code (`claude auth login`) numa pasta própria, em `~/.claude-<nome>` (editável). O navegador abre para você entrar.
3. Quando o login termina, a conta aparece na lista. O app guarda o login no Keychain; ele não lê nem copia o token do Claude Code.
4. Associe a conta a um perfil no editor de perfil.

Pastas que já existem (como `~/.claude`) são adotadas, sem apagar nada. A conta padrão é a que não define `CLAUDE_CONFIG_DIR`.

### adicionar-conta-github · Adicionar uma conta GitHub
palavras-chave: conta github, gh, github cli, login github, entrar no github, outra conta github

1. Janela › GitHub › "Adicionar conta" e informe usuário e host (github.com por padrão).
2. Use "Entrar…" para abrir o login do GitHub: o app mostra um código, "Copiar código e abrir o GitHub".
3. A troca usa `gh auth switch`; a conta precisa estar logada no `gh` para entrar num perfil.

### trocar-so-conta-claude · Trocar só a conta Claude
palavras-chave: trocar conta claude, mudar conta claude, so claude, apenas claude, sobrepor conta

No menu, "Trocar só a conta Claude" mostra as contas da pasta do perfil ativo. Escolher uma delas troca apenas o Claude, sem mexer em git nem gh. A escolha vale até a próxima troca de perfil. "Agents, skills e conversas não mudam."

### chaves-de-api · Guardar chaves de API no perfil
palavras-chave: chave api, api key, openai, gemini, token de api, variavel de ambiente, keychain chave

1. Janela › Chaves de API › "Adicionar chave".
2. Escolha o provedor e a variável (por exemplo `OPENAI_API_KEY`) e cole o valor.
3. O valor fica só no Keychain (item `app.multicred.apikey`). O hook do shell lê com `/usr/bin/security` quando o perfil muda.
4. Marque a chave nos perfis que devem usá-la.

As chaves não vão para apps gráficos, só para terminais.

### desinstalar · Desinstalar o MultiCred
palavras-chave: desinstalar, remover multicred, apagar multicred, restaurar arquivos

Ajustes › "Desinstalar…". Remove só os blocos do MultiCred (zshrc, bash, gitconfig), o arquivo do fish, a variável do launchd, as chaves de API do Keychain e a pasta do app. Os backups ficam em `MultiCred-backups-<data>`. As contas continuam logadas nas próprias ferramentas e as pastas `~/.claude*` não são apagadas.

### migrar-perfis · Migrar da versão antiga (~/Perfis)
palavras-chave: perfis antigo, migrar, scripts antigos, perfis.conf, legado, versão antiga

O onboarding detecta a versão antiga em `~/Perfis`, oferece remover as linhas antigas dos arquivos de shell e importa o `perfis.conf`. Dois hooks brigariam pelo `CLAUDE_CONFIG_DIR`, por isso o app pede para remover o antigo. Se ficou algum resto, a tela Verificar mostra "Versão antiga (~/Perfis) ainda ativa" com o botão de correção.

### verificar-e-corrigir · Verificar se está tudo certo
palavras-chave: verificar, checar, diagnostico, corrigir, esta certo

Menu › "Verificar…" (⌘R) compara o estado real de git, gh, Claude Code, launchd, shells e Keychain com o que o perfil ativo espera. Cada problema tem um botão "Corrigir" que mostra o comando antes de rodar. "Copiar diagnóstico" em Ajustes copia versão, ferramentas e o fim do log.

### conectar-ao-claude · Conectar este ajudante ao Claude
palavras-chave: mcp, conectar claude, ajuda claude, claude mcp add, assistente

Ajustes › "Ajuda com o Claude" mostra o comando `claude mcp add` para cada pasta de Claude e copia com um clique. Cole no terminal. Para desconectar: `claude mcp remove multicred --scope user`. O ajudante só lê: nunca altera arquivos nem mostra segredos.

## Problemas

### terminal-nao-trocou · O terminal aberto não trocou de conta
sintomas: terminal nao troca, terminal antigo, shell nao atualiza, git com e-mail errado, variavel nao mudou, aba aberta

1. Terminais trocam no próximo prompt, mas só nos shells marcados em Ajustes › Shells. Confira se o seu shell está marcado.
2. Abra um novo Terminal: o bloco `# >>> MultiCred >>>` precisa estar carregado. A tela Verificar mostra "carrega o MultiCred" em erro se a linha foi removida.
3. Rode Verificar › "Corrigir tudo" (reescreve o bloco, com backup).
4. Sessões do Claude Code abertas antes da troca continuam na conta antiga até serem reiniciadas.

### login-claude-falhou · O login do Claude falhou ou a conta está deslogada
sintomas: login claude falhou, claude deslogado, precisa entrar, sem login, claude auth, pasta sem login, navegador nao abriu

1. Menu › "Trocar só a conta Claude" mostra "· Entrar…" na pasta sem login.
2. Use "Entrar…": o app roda `claude auth login` e abre o navegador. Termine o login lá.
3. Se falhou, o terminal embutido mostra a saída real; "Tentar de novo" repete.
4. Confirme que o Claude Code está instalado (`curl -fsSL https://claude.ai/install.sh | bash`) e que `claude auth status` responde.

### gh-conta-errada · O gh está na conta errada do GitHub
sintomas: gh conta errada, github conta errada, gh auth switch, push com outro usuario, conta ativa errada

1. Verificar mostra "GitHub CLI · conta ativa" em erro com a conta esperada.
2. "Corrigir" roda `gh auth switch` para a conta do perfil.
3. Se a conta não está no `gh`, use GitHub › "Entrar…" para logar de novo.
4. Se o `gh` pede novo login, o aviso é "o gh precisa de um novo login".

### keychain-pediu-senha · O Mac pediu a senha do Keychain
sintomas: keychain pediu senha, senha do mac, pede senha toda vez, chave api pede senha, acesso ao keychain

Itens criados por versões antigas fazem o shell pedir a senha do Mac a cada leitura. Verificar mostra "os terminais pedem a senha do Mac"; cole a chave ou gere o token de novo para o item ser recriado sem esse problema. O app lê esses itens só pelo `/usr/bin/security`.

### sessao-claude-antiga · Uma sessão do Claude Code continua na conta antiga
sintomas: sessao aberta, claude continua conta antiga, nao trocou claude, processo claude

Uma sessão do Claude Code lê a conta ao abrir. Depois da troca, sessões já abertas continuam na conta em que foram abertas até serem reiniciadas. Feche e abra o `claude` de novo.
