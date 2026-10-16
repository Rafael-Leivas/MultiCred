# Security policy

MultiCred edits shell and git configuration and handles API keys, so security reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private reporting:
**Security › Report a vulnerability** on this repository
(<https://github.com/Rafael-Leivas/MultiCred/security/advisories/new>).

You will get a first answer within 7 days. Fixes ship as a new release and are credited in the advisory
(unless you prefer not to be named).

## Supported versions

Only the latest release receives security fixes.

## What MultiCred does and does not do

- Never reads, copies or stores Claude Code or GitHub CLI tokens.
- Changes only a marked block (`# >>> MultiCred >>>`) in your shell and git config files, with a backup first.
- API keys live in the macOS Keychain, never in plain files or logs.
- No telemetry and no network calls of its own; the only network traffic comes from the tools it runs (`gh`, `claude`).
- Commands run with absolute paths, argument arrays and a clean environment, never through a shell with user data.

The detailed audit is in [docs/SECURITY.md](docs/SECURITY.md).

## Verifying a download

Each release includes `SHA256SUMS.txt` and a build provenance attestation:

```sh
shasum -a 256 -c SHA256SUMS.txt
gh attestation verify MultiCred.dmg --repo Rafael-Leivas/MultiCred
```

Official builds are signed with an Apple Developer ID and notarized. Check with
`spctl -a -vv /Applications/MultiCred.app`.
