# Como publicar uma versão

## Uma vez só

1. **Apple Developer Program** (US$ 99/ano) e certificado **Developer ID Application**
   (Xcode › Settings › Accounts › Manage Certificates, ou developer.apple.com).
2. Exporte o certificado do Keychain como `.p12` (com senha) e converta: `base64 -i cert.p12 | pbcopy`.
3. Crie uma **senha específica de app** em appleid.apple.com (Segurança › Senhas específicas de app).
4. No GitHub: **Settings › Secrets and variables › Actions**, crie:

   | Secret | Valor |
   |---|---|
   | `MACOS_CERTIFICATE` | o `.p12` em base64 |
   | `MACOS_CERTIFICATE_PASSWORD` | a senha do `.p12` |
   | `NOTARY_APPLE_ID` | e-mail do Apple ID |
   | `NOTARY_TEAM_ID` | Team ID (10 caracteres) |
   | `NOTARY_PASSWORD` | a senha específica de app |

   Sem esses segredos o workflow ainda publica, mas como **pré-lançamento** e sem notarização.
5. Ative **Settings › Code security**: Private vulnerability reporting, Dependabot alerts e secret scanning.
6. Crie o repo `homebrew-tap` e copie `packaging/multicred.rb` para `Casks/multicred.rb`.

## A cada versão

```sh
# 1. suba MARKETING_VERSION no Xcode e mova o [Unreleased] do CHANGELOG.md para a nova versão
# 2. commit, merge em main, e então:
git tag v0.1.0 && git push origin v0.1.0
```

O workflow `Release` confere se a tag bate com `MARKETING_VERSION`, compila, assina, notariza, gera
`.dmg`, `.zip`, `SHA256SUMS.txt` e a atestação de procedência, e cria a Release. Depois, atualize
`version` e `sha256` no cask do tap.

## Testar local

```sh
scripts/release.sh                                   # ad hoc
DEVELOPER_ID="Developer ID Application: ..." NOTARY_PROFILE=multicred-notary scripts/release.sh
spctl -a -vv dist/MultiCred.app                      # deve dizer "Notarized Developer ID"
```
