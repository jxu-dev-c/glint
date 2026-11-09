#!/usr/bin/env bash
# Print the Homebrew cask for a release; CI writes it to jxu-dev-c/homebrew-tap as Casks/glint.rb.
#
#   scripts/render-cask.sh VERSION SHA256
set -euo pipefail

VERSION="${1:?usage: render-cask.sh VERSION SHA256}"
SHA256="${2:?usage: render-cask.sh VERSION SHA256}"

cat <<CASK
cask "glint" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/jxu-dev-c/glint/releases/download/v#{version}/Glint-#{version}.zip"
  name "Glint"
  desc "Menu bar control for display brightness, resolution and HDR"
  homepage "https://github.com/jxu-dev-c/glint"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Glint.app"

  # signed ad hoc, not notarized
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Glint.app"],
                          writable_paths: ["Glint.app"], writable_base: :appdir
  end

  uninstall quit: "com.jasonxu.glint"

  zap trash: "~/Library/Preferences/com.jasonxu.glint.plist"
end
CASK
