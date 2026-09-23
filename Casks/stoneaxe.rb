cask "stoneaxe" do
  version "0.1.0"
  sha256 "7c24c7db641bc1c66fa68c76552ecf98763c3070c7173df6b2b64830f77b7ada"

  url "https://github.com/s3mng/stoneaxe/releases/download/v#{version}/Stoneaxe-#{version}-arm64.zip"
  name "Stoneaxe"
  desc "Adaptive Bitcoin solo miner for the macOS menu bar"
  homepage "https://github.com/s3mng/stoneaxe"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Stoneaxe.app"

  caveats <<~EOS
    Stoneaxe is currently ad-hoc signed and not notarized. If macOS blocks its
    first launch, open Applications in Finder, Control-click Stoneaxe, choose
    Open, then confirm Open. This creates an exception only for Stoneaxe.
  EOS

  zap trash: [
    "~/Library/Application Support/Stoneaxe",
    "~/Library/Logs/Stoneaxe",
    "~/Library/Preferences/app.stoneaxe.mac.plist",
  ]
end
