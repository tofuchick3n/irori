# Homebrew cask template. Fill in sha256 once a notarized release exists
# (scripts/make-dmg with NOTARY_PROFILE, uploaded to GitHub Releases).
cask "irori" do
  version "0.9.0"
  sha256 "REPLACE_WITH_SHA256_OF_THE_DMG"

  url "https://github.com/tofuchick3n/irori/releases/download/v#{version}/irori-#{version}.dmg"
  name "irori"
  desc "Roundtable of AI agents in one thread, with optional Takibi Base"
  homepage "https://github.com/tofuchick3n/irori"

  depends_on macos: ">= :tahoe"

  app "irori.app"

  zap trash: [
    "~/Library/Application Support/Irori",
    "~/Library/Preferences/io.github.tofuchick3n.irori.plist",
  ]
end
