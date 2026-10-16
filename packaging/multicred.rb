# Homebrew Cask template. Copy to the repo Rafael-Leivas/homebrew-tap as Casks/multicred.rb
# after each release, updating version and sha256 (from SHA256SUMS.txt).
# Install: brew install --cask Rafael-Leivas/tap/multicred
cask "multicred" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_OF_MultiCred.dmg"

  url "https://github.com/Rafael-Leivas/MultiCred/releases/download/v#{version}/MultiCred.dmg"
  name "MultiCred"
  desc "Menu bar app that switches git, GitHub CLI, Claude Code and API key identities"
  homepage "https://github.com/Rafael-Leivas/MultiCred"

  depends_on macos: ">= :sonoma"

  app "MultiCred.app"

  zap trash: [
    "~/Library/Application Support/MultiCred",
    "~/Library/Logs/MultiCred",
  ]
end
