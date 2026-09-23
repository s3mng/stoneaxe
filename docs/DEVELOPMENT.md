# Development

## Source layout

| Path | Purpose |
| --- | --- |
| `Sources/StoneaxeCore/` | Bitcoin types, target math, address validation, scheduling policy |
| `Sources/Stoneaxe/` | AppKit/SwiftUI, Stratum, engine, storage, translations |
| `Sources/Stoneaxe/Resources/Mining.metal` | SHA-256d kernel |
| `Tests/` | Bitcoin vectors, policy and engine regression tests |
| `Packaging/` | App metadata, icon, and cask template |
| `scripts/` | Build, artwork, signing, notarization, and cask generation |

## Build and verify

```sh
swift test
bash scripts/build-app.sh
dist/Stoneaxe.app/Contents/MacOS/Stoneaxe --self-test
```

The app has no third-party packages. If the local build database has I/O errors,
use `STONEAXE_BUILD_PATH=/private/tmp/stoneaxe-build bash scripts/build-app.sh`.
App replacement preserves previous bundles inside `dist/.stoneaxe-previous.*`
instead of overwriting a running executable.

The current kernel recomputes the first SHA compression for each nonce. Midstate
caching is a possible optimization, subject to CPU/GPU differential tests.

## App icon

Native vector geometry in `scripts/generate-icon.swift` generates all required
icon sizes and the README image. Regenerate on macOS:

```sh
swift scripts/generate-icon.swift
iconutil -c icns dist/Stoneaxe.iconset -o Packaging/Stoneaxe.icns
```

Commit the generator, `Packaging/Stoneaxe.icns`, and `docs/images/` together.
Normal builds use the checked-in icon without regenerating it.

## Releases and Homebrew

Release ZIPs are hosted in [s3mng/stoneaxe](https://github.com/s3mng/stoneaxe).
The cask lives in [s3mng/homebrew-tap](https://github.com/s3mng/homebrew-tap).

1. Update version/build numbers in `Packaging/Info.plist` and test on real hardware.
2. Provide a **Developer ID Application** identity and notarization keychain profile:

   ```sh
   STONEAXE_SIGN_IDENTITY='Developer ID Application: …' \
   STONEAXE_NOTARY_PROFILE='stoneaxe' bash scripts/release.sh
   ```

3. Generate the cask from the final ZIP:

   ```sh
   ruby scripts/generate-cask.rb s3mng/stoneaxe \
     dist/Stoneaxe-0.1.0-arm64.zip dist/stoneaxe.rb 0.1.0
   ```

4. Publish the ZIP in GitHub Release `v0.1.0`, copy the cask to
   `Casks/stoneaxe.rb` in the tap, and verify installation on a clean Mac.

The first release is ad-hoc signed and warns on first launch. A future Developer
ID Application signature and notarization can remove that warning. An Apple
Development certificate does not replace Developer ID Application.

### GitHub Actions

CI runs tests and builds an ad-hoc-signed app. The manual signed-release workflow
creates a **draft release** containing a notarized ZIP and generated cask. It does
not publish the draft or update the separate tap.

Configure these secrets in the `release` environment:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | Base64 Developer ID Application `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | `.p12` password |
| `KEYCHAIN_PASSWORD` | Temporary CI keychain password |
| `APPLE_SIGN_IDENTITY` | Full Developer ID identity name |
| `APPLE_ID` | Notarization Apple ID |
| `APPLE_TEAM_ID` | Developer team ID |
| `APPLE_APP_PASSWORD` | App-specific notarization password |

Never commit credentials. Validate the downloaded artifact before publishing.
Hosted CI runners may not expose a Metal GPU; run the GPU test on real hardware.

## Before a public release

- Unit tests and offline GPU/CPU comparisons pass.
- A real CKPool connection authorizes, receives work, and accepts a share.
- Both languages, text shortcuts, and window/menu interactions work.
- Pause/resume, battery changes, sleep/wake, and reconnection behave correctly.
- Scrolling, video playback, and GPU-heavy apps remain responsive while mining.
- Sustained memory and thermal measurements meet the intended defaults.
- Notifications, candidate/inclusion/reorganization states, and persistence are exercised.
- The release checksum matches the cask and installation works on a clean Mac.

Offline tests do not replace these integration checks.
