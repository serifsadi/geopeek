# Releasing

`scripts/release.sh` reads the marketing version and build number from `GeoPeek.xcodeproj`, archives a Release build with the hardened runtime, exports it with the Developer ID method, and writes `GeoPeek-<version>.dmg` in the repository root. It does not create a git tag or a GitHub release.

`scripts/release-mas.sh` builds that same version for the Mac App Store. It does not build the disk image, and it does not replace `release.sh`. See [Mac App Store](#mac-app-store).

The script notarizes the app and staples that ticket, then builds the disk image from the stapled app, signs the image, and notarizes and staples the image. Apple's notary service is contacted twice.

People upgrading from 0.1.x or 0.2.0 get one macOS prompt that GeoPeekExtension differs from previously opened versions. Those older copies were ad-hoc signed. This build is signed with a Developer ID certificate.

## One-time setup

1. On Apple Developer team `7W797GT86L`, create a **Developer ID Application** certificate and install it in the login keychain. Confirm it is present:

   ```bash
   security find-identity -v -p codesigning
   ```

2. In Xcode, open Settings → Accounts and sign in with an Apple ID that can create provisioning profiles for that team. The script passes `-allowProvisioningUpdates` so export can create the Developer ID profiles for the app and both extensions.

3. Create an app-specific password at [account.apple.com](https://account.apple.com) (Sign-In and Security → App-Specific Passwords).

4. Store the notary credentials in the login keychain. Run this yourself in Terminal. It prompts for the Apple ID, the team ID, and the app-specific password. The release script never takes the password:

   ```bash
   xcrun notarytool store-credentials "geopeek-notary"
   ```

   The profile name is any label you choose. `NOTARY_PROFILE` has to be that same label. The keychain profile in use is `geopeek-notary`.

5. Install `create-dmg` and leave it on `PATH`. The release script does not call Homebrew itself:

   ```bash
   brew install create-dmg
   command -v create-dmg
   ```

   The first time `create-dmg` runs, macOS asks for permission to let Terminal control Finder. Allow it. That permission is what places the icon and the Applications alias.

The login keychain needs to be unlocked (a normal Terminal.app session is).

Use the script for the notarized build. The Quick Look targets stay ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`) so a Debug build from Xcode does not need the Developer ID certificate. The script overrides that identity when it archives.

## Each release

From the repository root:

```bash
export DEVELOPMENT_TEAM="7W797GT86L"
export NOTARY_PROFILE="geopeek-notary"
./scripts/release.sh
```

`DEVELOPMENT_TEAM` is written into a temporary copy of `scripts/ExportOptions.plist`. The committed plist has no team ID. `NOTARY_PROFILE` is whatever name you gave `notarytool store-credentials`. `geopeek-notary` is the profile stored for this team.

Set `SIGN_IDENTITY` only when `codesign` needs a longer certificate name to sign the disk image. Leave it unset to use the Developer ID that signed the app.

The script stops if the project versions disagree, if `create-dmg` is missing, or if any signature, Gatekeeper, staple, version, or bundle-layout check fails.

## Mac App Store

The Developer ID disk image and the Homebrew cask stay on `scripts/release.sh`. The Mac App Store build is the same app: same scheme (`GeoPeek`), same `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, same entitlements, same features. Homebrew keeps installing the notarized disk image from GitHub Releases. It does not install the App Store package. This script does not tag, and it does not publish either channel.

### Why a second archive

`exportArchive` can re-sign an archive, so one archive can feed two exports in the general case. This repository does not do that.

`release.sh` archives with manual signing and `CODE_SIGN_IDENTITY="Developer ID Application"`. That signature is what the disk image and notarization use. The Quick Look targets set `CODE_SIGN_IDENTITY[sdk=macosx*]` to ad-hoc (`"-"`) so a Debug build from Xcode does not need a certificate, and a plain `CODE_SIGN_IDENTITY` on the `xcodebuild` command line is what overrides it. The Developer ID archive uses that override.

App Store Connect needs a different pair of certificates. The app is signed with Apple Distribution (older name: 3rd Party Mac Developer Application). The installer package is signed with Mac Installer Distribution (older name: 3rd Party Mac Developer Installer). The profiles are Mac App Store profiles, not Developer ID profiles. One archive command cannot pass both the Developer ID identity and the Apple Distribution identity. Pointing the App Store exporter at the Developer ID archive would also tie the two release paths together. Changing `release.sh` so both exports shared one archive would change the disk image path.

`release-mas.sh` therefore archives again, from the same scheme and Release configuration. The archive uses manual signing and `CODE_SIGN_IDENTITY="Apple Distribution"`, the same kind of override `release.sh` uses for Developer ID. Pairing that identity with automatic style makes Xcode reject the archive. Export then uses `scripts/ExportOptions-MAS.plist` (`method` `app-store-connect`, `signingStyle` `automatic`). That export signs the package, and it is where Xcode can create the Mac Installer Distribution certificate. The certificate does not have to exist before the first export. The plist does not name a signing certificate. It sets `manageAppVersionAndBuildNumber` to false so export keeps the project version.

### Before the first upload

1. The App IDs `dev.serifsadi.GeoPeek`, `dev.serifsadi.GeoPeek.GeoPeekExtension`, and `dev.serifsadi.GeoPeek.GeoPeekThumbnailExtension` are registered on team `7W797GT86L`. The App Store Connect record for GeoPeek exists.

2. In Xcode, open Settings, Accounts, and sign in with an Apple ID that can create profiles for that team. Automatic signing creates the Mac App Store profiles during archive and export (`-allowProvisioningUpdates`).

3. Archive needs an Apple Distribution certificate. Confirm it:

   ```bash
   security find-identity -v -p codesigning
   ```

   If it is missing, create it in Xcode: Settings, Accounts, Manage Certificates, add Apple Distribution.

4. A Mac Installer Distribution certificate does not have to exist yet. The first export creates it when Xcode signs the package. You may be asked to approve that in the Apple ID account.

5. Upload is optional. Create an App Store Connect API key (Users and Access, Integrations, App Store Connect API). Keep the `.p8` file outside this repository. The script reads `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_PATH`. Nothing in the repository is a credential.

The notary keychain profile and `create-dmg` are only used by `release.sh`. Do not notarize the App Store package. Review does that.

`DEVELOPMENT_TEAM` is required, as with `release.sh`. The script writes it into a temporary copy of `scripts/ExportOptions-MAS.plist`. The committed plist already records team `7W797GT86L` so it can be selected from Xcode. `manageAppVersionAndBuildNumber` is false. The version stays whatever the project says.

### Each App Store build

From the repository root:

```bash
export DEVELOPMENT_TEAM="7W797GT86L"
./scripts/release-mas.sh
```

This writes `GeoPeek-<version>.pkg` in the repository root. `<version>` is `MARKETING_VERSION`. The script stops if the project versions disagree, or if the package signature, the app signature, the hardened runtime, the entitlements, the version, or the bundle layout is wrong. It also checks that `Credits.html` is in the app and that the category, copyright, and encryption flag are in the built Info.plist.

To upload that same archive to App Store Connect:

```bash
export DEVELOPMENT_TEAM="7W797GT86L"
export UPLOAD=1
export ASC_KEY_ID="your-key-id"
export ASC_ISSUER_ID="your-issuer-id"
export ASC_KEY_PATH="/path/outside/the/repo/AuthKey_your-key-id.p8"
./scripts/release-mas.sh
```

When those three key variables are set, archive and export pass them to `xcodebuild`, so provisioning does not depend on a signed-in Apple ID. When they are unset, export uses the Xcode account, the same way `release.sh` does. `UPLOAD=1` requires all three, and the key path has to be outside the repository.

The upload is a second export of the same archive with `destination` set to `upload`. The `.pkg` left in the repository root is the export the script checked. Ship the same project version on both channels when you release. Publishing the disk image is still `release.sh`, then the usual tag and cask update.
