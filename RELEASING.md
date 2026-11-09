# Releasing

`scripts/release.sh` reads the marketing version and build number from `GeoPeek.xcodeproj`, archives a Release build with the hardened runtime, exports it with the Developer ID method, and writes `GeoPeek-<version>.dmg` in the repository root. It does not create a git tag or a GitHub release.

The script notarizes the app and staples that ticket, then builds the disk image from the stapled app, signs the image, and notarizes and staples the image. Apple's notary service is contacted twice.

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
