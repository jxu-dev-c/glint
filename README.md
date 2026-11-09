# Glint

A tiny menu bar app for macOS that does three things for each connected display:

- **Brightness**: built-in and Apple displays through macOS, other monitors over DDC/CI, and software (gamma) dimming when a monitor doesn't answer DDC, as is common over the HDMI port of Apple Silicon Macs.
- **Resolution**: every desktop mode the display offers, HiDPI included.
- **HDR**: on/off, for displays that support it.

That's all it does. It's pure AppKit with no dependencies, ships as a binary of about 160 KB, and uses roughly 13 MB of memory.

## Install

```sh
brew install --cask jxu-dev-c/tap/glint
```

Requires macOS 14 or later on Apple Silicon.

## Build

```sh
scripts/build-app.sh   # → build/Glint.app
open build/Glint.app
```

## Notes

- Brightness and HDR use private macOS APIs (DisplayServices, IOAVService, SkyLight), the same ones used by MonitorControl and BetterDisplay. A future macOS could break them. If an API is missing, Glint hides that control rather than crashing.
- Software dimming is reset when Glint quits.
- Glint isn't notarized. The Homebrew cask removes the quarantine flag on install.

## Release

Push a `vX.Y.Z` tag. The release workflow builds the app, publishes a GitHub Release, and updates `Casks/glint.rb` in [jxu-dev-c/homebrew-tap](https://github.com/jxu-dev-c/homebrew-tap). This needs a `HOMEBREW_TAP_TOKEN` secret.

## License

MIT
