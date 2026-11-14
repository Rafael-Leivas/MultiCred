# MultiCred

macOS 14+ menu bar app (Swift/SwiftUI) that switches git, GitHub CLI, Claude Code and API key identities.
Logic lives in `Packages/MultiCredCore`; plan and decisions in `docs/PLAN.md`; audit in `docs/SECURITY.md`.

## Build and test

- `swift test --package-path Packages/MultiCredCore`
- `xcodebuild -project MultiCred.xcodeproj -scheme MultiCred -configuration Debug build`
- `scripts/release.sh` builds `dist/MultiCred.app` (includes `Contents/Helpers/multicred-mcp`).

## Safety

Debug builds run in test mode (sandbox HOME, dry-run runner, simulated logins). Never touch the real
`~/.zshrc`, `~/.gitconfig`, `~/.claude*`, gh config or Keychain, and never run `launchctl setenv`, without
explicit authorization. Code goes through the injected runner and file-writing layers.

## Help MCP server: always ask to keep it updated

`Packages/MultiCredCore/Sources/MultiCredHelp` is a read-only MCP server whose single-source guide is
`Guide/guia.md`. Whenever you change a screen, a setting, a generated file or path, a command, a Verify check
or any user-visible behavior, **before finishing the task ask the user**:

> Deseja atualizar as tools do MCP (e o guia) para refletir esta mudança?

Never skip the question and never update silently. If the answer is yes, update `guia.md` (and the tools if
what they should do changed) and run the tests: `GuideConsistencyTests` points at what is stale. The server
must stay read-only and offline: do not add tools, network, writes or credential reads without a spec change
(`MCPArchitectureGuardTests` enforces it).
