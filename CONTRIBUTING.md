# Contributing

Thanks for helping. MultiCred is a macOS 14+ menu bar app written in Swift (SwiftUI) with the logic in the
`Packages/MultiCredCore` Swift package.

## Build and test

```sh
swift test --package-path Packages/MultiCredCore   # core tests
open MultiCred.xcodeproj                           # scheme "MultiCred" runs in test mode
scripts/release.sh                                 # builds dist/MultiCred.app
```

The default scheme runs in **test mode**: it uses a sandbox HOME and never touches your real
`~/.zshrc`, `~/.gitconfig`, `~/.claude*`, gh config or Keychain. Please keep it that way: new code that
writes to the system must go through the existing runner and file-writing layers so test mode covers it.

## Pull requests

Nobody pushes directly to `main` or `dev`, maintainers included. The flow is:

1. **Fork** the repository and create a branch there (`fix/short-name` or `feat/short-name`).
2. Open a pull request **against `dev`**. PRs against `main` are closed; `main` only receives merges from `dev`.
3. CI must pass and a maintainer reviews. Maintainers: @Rafael-Leivas and Caio Kormives.
4. Accepted PRs are squash-merged into `dev`. Maintainers promote `dev` to `main` with a PR and cut releases from `main`.

Guidelines:

- Open an issue first for anything larger than a small fix.
- Add or update tests in `MultiCredCore` for logic changes.
- Keep PRs focused; describe what changes for the user.
- Commit messages in English, present tense.

## Keeping the help MCP server up to date

MultiCred ships a read-only help server (`multicred-mcp`) whose guide lives in
`Packages/MultiCredCore/Sources/MultiCredHelp/Guide/guia.md`. When a change alters a screen, a setting, a
generated file or path, a command, a Verify check or any user-visible behavior, ask the maintainer
(Portuguese, as the guide): "Deseja atualizar as tools do MCP (e o guia) para refletir esta mudança?"
Do not skip the question and do not update silently. `swift test` fails (`GuideConsistencyTests`) when the
guide cites something that no longer exists. Adding a tool needs a spec change and a security review
(`docs/SECURITY.md`).

## Security

Report vulnerabilities privately, see [SECURITY.md](SECURITY.md).
