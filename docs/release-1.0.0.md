# GeoPeek 1.0.0 launch

Prepared for launch day. Nothing in this file creates a tag, a GitHub Release, or a merge.

Tag `v1.0.0` points at `9301ff20ee9c929eb6d9dbb3f13269fa58fd25bf` (`9301ff2`), the commit the notarized Developer ID disk image and the Mac App Store build 1.0.0 (5) were made from. Merging the pull request that adds these notes does not move that commit.

`docs/release-1.0.0-tag.txt` is the annotated tag message. `docs/release-1.0.0-notes.md` is the GitHub Release body. Both are copied below. `gh release create` reads the notes file, not this document.

## Annotated tag message

`git tag -a v1.0.0 9301ff20ee9c929eb6d9dbb3f13269fa58fd25bf -F docs/release-1.0.0-tag.txt`

```
GeoPeek 1.0.0

1.0.0 (5) at 9301ff20ee9c929eb6d9dbb3f13269fa58fd25bf.

Help opens Acknowledgements, the privacy policy, and support. About shows one short centered credit, and ThirdPartyNotices.txt ships in the app. Map attribution stays expanded. System Settings lists GeoPeek Preview and GeoPeek Thumbnail. Popup values stay clear of the close button.

GitHub Releases and Homebrew stay free. The Mac App Store app is a one-time purchase: https://apps.apple.com/app/id6839084436
```

## GitHub Release body

Title: `GeoPeek 1.0.0`. The body is `docs/release-1.0.0-notes.md`:

```markdown
## What's New

- **Help**: The Help menu opens Acknowledgements, the privacy policy (https://geopeek.app/privacy/), and support (https://geopeek.app/support/). Acknowledgements shows the bundled third-party notices as plain text. About GeoPeek shows one short centered credit. The full license text ships in the app as ThirdPartyNotices.txt.
- **Map attribution**: Stays expanded. The compact control is left as MapLibre creates it.
- **System Settings**: The extensions are listed as GeoPeek Preview and GeoPeek Thumbnail.
- **Popup**: Long feature names stay clear of the close button. Each property value wraps beside it. The app and Quick Look use the same page.
- **Build**: 1.0.0 (5). The app records its App Store category, copyright, and encryption flag. This Developer ID disk image is that version.

GeoPeek is also on the Mac App Store as a one-time paid app: https://apps.apple.com/app/id6839084436

GitHub Releases and Homebrew stay free.

## Install

`brew install --cask serifsadi/geopeek/geopeek`, or download **GeoPeek-1.0.0.dmg**, open it, and drag GeoPeek to Applications.

SHA-256 (GeoPeek-1.0.0.dmg): `5eb51ca851e7d0e7f7db1d6b0f6dc2e6eac524ee076dbd37659940bc4650cf93`

2789547 bytes.
```

The notes come from `CHANGELOG.md` and the commits after `v0.4.1`: the website link in the README (`f59879e`), Mac App Store packaging (`d63b381`), the 1.0.0 (5) version bump (`3014402`), and the popup close button (`9301ff2`). The popup fix is in the tagged commit and was not in the changelog entry written by `3014402`. The README website link is not an app change, so it is not in the release body.

On launch day, replace `YYYY-MM-DD` in `CHANGELOG.md` with that day's date. That commit stays off `v1.0.0`. The tagged tree still says `## 1.0.0 - 2026-11-25` and does not mention the popup fix. The GitHub Release body is the notes file.

## Launch runbook

Run the steps in this order. The disk image is the existing file `GeoPeek-1.0.0.dmg` (SHA-256 `5eb51ca851e7d0e7f7db1d6b0f6dc2e6eac524ee076dbd37659940bc4650cf93`, 2789547 bytes), already notarized and stapled. Leave `scripts/release.sh` and `scripts/release-mas.sh` unrun.

### 1. App Store Connect

Release the Mac App Store version that is already uploaded. GeoPeek 1.0.0, build 5, status Pending Developer Release. Move that version to Release. Leave the build number as 5.

### 2. Tag v1.0.0 and the GitHub Release

From a clone that contains `9301ff20ee9c929eb6d9dbb3f13269fa58fd25bf`, this notes file, and the disk image in the current directory. Confirm the commit and the file before tagging:

```bash
git rev-parse 9301ff20ee9c929eb6d9dbb3f13269fa58fd25bf
shasum -a 256 GeoPeek-1.0.0.dmg
stat -f %z GeoPeek-1.0.0.dmg
xcrun stapler validate GeoPeek-1.0.0.dmg
spctl -a -vv -t open --context context:primary-signature GeoPeek-1.0.0.dmg
```

`git rev-parse` prints `9301ff20ee9c929eb6d9dbb3f13269fa58fd25bf`. The SHA-256 is `5eb51ca851e7d0e7f7db1d6b0f6dc2e6eac524ee076dbd37659940bc4650cf93`. `stat` prints `2789547`. `stapler validate` reports the ticket is validated. `spctl` reports accepted. This `spctl` form is the one `scripts/release.sh` uses for the disk image.

Create the annotated tag on that commit, push it, then create the release. `gh release create` reads `docs/release-1.0.0-notes.md`. `--verify-tag` makes `gh` stop when `v1.0.0` is not already on the remote, so `gh` does not create a lightweight tag at the default branch tip.

```bash
git tag -a v1.0.0 9301ff20ee9c929eb6d9dbb3f13269fa58fd25bf -F docs/release-1.0.0-tag.txt
git push origin v1.0.0
gh release create v1.0.0 GeoPeek-1.0.0.dmg \
  --repo serifsadi/geopeek \
  --verify-tag \
  --target 9301ff20ee9c929eb6d9dbb3f13269fa58fd25bf \
  --title "GeoPeek 1.0.0" \
  --notes-file docs/release-1.0.0-notes.md
```

The asset name on the release is `GeoPeek-1.0.0.dmg`. The command publishes the release. It is the launch-day command, and it is not part of preparing this document.

### 3. Homebrew cask

Merge the open pull request in [serifsadi/homebrew-geopeek](https://github.com/serifsadi/homebrew-geopeek) that sets the cask to 1.0.0 after the GitHub asset exists. The download URL in the cask stays `https://github.com/serifsadi/geopeek/releases/download/v#{version}/GeoPeek-#{version}.dmg`. The diff sets:

- `version "1.0.0"`
- `sha256 "5eb51ca851e7d0e7f7db1d6b0f6dc2e6eac524ee076dbd37659940bc4650cf93"`

`main` on 2026-11-27 is still `version "0.4.1"` and `sha256 "1599113e78b97d86ea1f988a304fdfa13345e2678972449e1e531b5fe0b7db30"`. The only pull request in that repository is [serifsadi/homebrew-geopeek#1](https://github.com/serifsadi/homebrew-geopeek/pull/1), already merged, and it only changes `homepage` to `https://geopeek.app`. List open pull requests on launch day and merge the one whose diff matches the version and checksum above:

```bash
gh pr list --repo serifsadi/homebrew-geopeek --state open
```

### 4. Website badge

Merge the open pull request in [serifsadi/geopeek-web](https://github.com/serifsadi/geopeek-web) that adds the Mac App Store badge linking to https://apps.apple.com/app/id6839084436. This step follows the App Store release so the badge points at a released app.

On 2026-11-27 that pull request is not open. Merged pull requests are [#1](https://github.com/serifsadi/geopeek-web/pull/1), [#2](https://github.com/serifsadi/geopeek-web/pull/2), and [#3](https://github.com/serifsadi/geopeek-web/pull/3). Pull request #3 says the home page still describes only the free GitHub and Homebrew download. List open pull requests on launch day and merge the badge one:

```bash
gh pr list --repo serifsadi/geopeek-web --state open
```

### 5. Verify

```bash
brew update && brew upgrade --cask geopeek
spctl -a -vv -t exec /Applications/GeoPeek.app
curl -fL -o /tmp/GeoPeek-1.0.0.dmg "https://github.com/serifsadi/geopeek/releases/download/v1.0.0/GeoPeek-1.0.0.dmg"
shasum -a 256 /tmp/GeoPeek-1.0.0.dmg
stat -f %z /tmp/GeoPeek-1.0.0.dmg
spctl -a -vv -t open --context context:primary-signature /tmp/GeoPeek-1.0.0.dmg
```

`brew upgrade --cask geopeek` is the check when the cask is already installed. A machine without it uses `brew install --cask serifsadi/geopeek/geopeek`.

`spctl -a -vv -t exec` is the app check from `scripts/release.sh`. Expect `accepted`, and the installed version:

```bash
defaults read /Applications/GeoPeek.app/Contents/Info.plist CFBundleShortVersionString
defaults read /Applications/GeoPeek.app/Contents/Info.plist CFBundleVersion
```

Those print `1.0.0` and `5`.

The download URL is https://github.com/serifsadi/geopeek/releases/download/v1.0.0/GeoPeek-1.0.0.dmg. The SHA-256 is `5eb51ca851e7d0e7f7db1d6b0f6dc2e6eac524ee076dbd37659940bc4650cf93`. `stat` prints `2789547`. The disk image `spctl` reports accepted.

Set `CHANGELOG.md` from `YYYY-MM-DD` to the launch date in a commit on `main`. Leave tag `v1.0.0` on `9301ff20ee9c929eb6d9dbb3f13269fa58fd25bf`.
