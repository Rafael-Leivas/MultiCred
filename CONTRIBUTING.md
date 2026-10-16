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

- Open an issue first for anything larger than a small fix.
- Add or update tests in `MultiCredCore` for logic changes.
- Keep PRs focused; describe what changes for the user.
- Commit messages in English, present tense.

## Security

Report vulnerabilities privately, see [SECURITY.md](SECURITY.md).
