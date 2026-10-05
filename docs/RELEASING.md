# Releasing MacMiniMixer

Maintainer guide for packaging MacMiniMixer as a direct-download `.zip` and publishing it as a
GitHub Release.

> **Guardrail:** v0.14 is an internal, unreleased checkpoint. `MARKETING_VERSION` stays `0.13` and
> no tag is pushed until the maintainer explicitly decides to cut a public release (see
> `docs/HANDOFF.md` §3). Nothing in this pipeline publishes a release on its own: a tag push only
> creates a **draft**, and a person publishes it.

## What gets shipped

- `MacMiniMixer-<version>.zip` contains `MacMiniMixer.app`, a Release build that is **ad-hoc
  signed and not notarized**. It ships with `MacMiniMixer-<version>.zip.sha256`.
- The app is **menu bar only**: `Info.plist` sets `LSUIElement`, so there is no Dock icon and no main
  window. The app lives in the menu bar and quits from the panel's **Quit MacMiniMixer** button.
- It runs on **macOS 13.0+**. Product Real Control and the other Process Tap features need
  **macOS 14.2+**. Product Real Control is **experimental**.
- The bundle identifier is still the placeholder `com.example.MacMiniMixer`. That's fine for
  ad-hoc builds, but change it before Developer ID distribution (see [Future](#future-developer-id-signing--notarization)).

| Workflow | Trigger | Result |
| --- | --- | --- |
| `Build` → `package` job | pushes to `main` and manual (`workflow_dispatch`) runs, after the `build` job passes; docs-only changes skip CI | artifact `MacMiniMixer-app` (`MacMiniMixer-<version>-<sha7>.zip` + `.sha256`), kept 14 days |
| `Release` | push of a `v*` tag | tests → zip → tag/version check → artifact + **draft** GitHub Release |
| `Release` | manual (`workflow_dispatch`) | tests → zip → artifact only, no GitHub Release (branch runs add a `-<sha7>` suffix) |

## 1. Pre-release checklist

- [ ] You're on `main` with a clean tree, and the latest `Build` workflow run is green.
- [ ] The full test suite passes locally with 0 failures:
      ```bash
      xcodebuild test -project MacMiniMixer.xcodeproj -scheme MacMiniMixer \
        -destination 'platform=macOS' -derivedDataPath ./.DerivedData CODE_SIGNING_ALLOWED=NO
      xcrun xcresulttool get test-results summary \
        --path "$(ls -td ./.DerivedData/Logs/Test/*.xcresult | head -1)"
      ```
- [ ] The essentials from `docs/MANUAL_TEST_CHECKLIST.md` pass on a real Mac (macOS 14.2+) with the
      **packaged** app, not an Xcode run. Cover at least §1 system output volume, §2 output devices,
      §3 app discovery, §4 Real App Control, §11 Stop / Stop All, §12 output-device change while
      active, §14 sleep/wake, and the §17/§18 Product Real smokes. Audio must be normal after quitting,
      with no `sudo killall coreaudiod` needed.
- [ ] `CHANGELOG.md` is final. Rename the `## [vX.Y] - Unreleased` section to
      `## [vX.Y] - YYYY-MM-DD` and fold in the relevant `[Unreleased]` entries. The release workflow
      copies the section whose heading starts with `## [vX.Y]` into the draft notes.
- [ ] The version is bumped in `MacMiniMixer.xcodeproj/project.pbxproj`, in all **4** build
      configurations (app Debug/Release and test Debug/Release):
      - `MARKETING_VERSION` gets the new version, for example `0.14`. It becomes
        `CFBundleShortVersionString`, which the tag must match.
      - `CURRENT_PROJECT_VERSION` gets the next build number, for example `1` → `2`. It becomes
        `CFBundleVersion`.
      ```bash
      sed -i '' -e 's/MARKETING_VERSION = 0.13;/MARKETING_VERSION = 0.14;/' \
                -e 's/CURRENT_PROJECT_VERSION = 1;/CURRENT_PROJECT_VERSION = 2;/' \
                MacMiniMixer.xcodeproj/project.pbxproj
      git grep -n -E 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' -- '*.pbxproj'  # expect 4 + 4, all new
      ```
- [ ] README "Current Status" and `docs/HANDOFF.md` say the version is released, not "unreleased
      checkpoint".
- [ ] The release commit is pushed and its `Build` run is green. That run's `MacMiniMixer-app`
      artifact is a good final smoke test.

## 2. Build a zip locally

```bash
scripts/package-app.sh                    # Release build → dist/MacMiniMixer-<version>.zip + .sha256
scripts/package-app.sh --skip-build       # reuse the existing ./.DerivedData Release build
scripts/package-app.sh --label rc1        # → dist/MacMiniMixer-<version>-rc1.zip
DIST_DIR=/tmp/mmm scripts/package-app.sh  # different output directory
```

The script does the following:

1. Builds with `xcodebuild build -configuration Release … CODE_SIGNING_ALLOWED=NO` into
   `./.DerivedData`.
2. Copies `MacMiniMixer.app` to a temporary folder, so the DerivedData product is left unchanged.
3. Reads the version from the built `Info.plist`.
4. Ad-hoc signs the copy (`codesign --force --deep --sign -`) and verifies it with
   `codesign --verify --deep --strict`.
5. Zips it with `ditto -c -k --sequesterRsrc --keepParent` and writes a `shasum -a 256` file.

`dist/` is git-ignored.

To check the zip:

```bash
cd "$(mktemp -d)" && ditto -x -k /path/to/dist/MacMiniMixer-0.14.zip .
codesign --verify --deep --strict --verbose=2 MacMiniMixer.app
codesign -dv MacMiniMixer.app 2>&1 | grep Signature   # Signature=adhoc
spctl --assess --type execute -vv MacMiniMixer.app    # "rejected" is expected: not notarized
lipo -archs MacMiniMixer.app/Contents/MacOS/MacMiniMixer
open MacMiniMixer.app
```

A zip you unpack locally is not quarantined, so Gatekeeper won't prompt. To see what users see,
download the zip in a browser, from the draft release or the workflow artifact.

## 3. Tag → draft release

```bash
git switch main && git pull --ff-only
git tag -a v0.14 -m "MacMiniMixer v0.14"
git push origin v0.14
gh run watch            # or watch the Release workflow in the Actions tab
```

The `Release` workflow (`.github/workflows/release.yml`) does the following:

1. Runs `xcodebuild test`, the same command CI uses.
2. Runs `scripts/package-app.sh`.
3. Checks that the tag is exactly `v` + `CFBundleShortVersionString` (`v0.14` ⇔ `0.14`).
4. Uploads the zip as a workflow artifact.
5. Creates a **draft** GitHub Release with the zip and `.sha256`. Its notes cover the ad-hoc /
   not-notarized status and how to open the app, macOS 13.0+ (14.2+ for per-app features), that
   Product Real Control is experimental, and this version's CHANGELOG section.

If something goes wrong:

- **"Tag does not match app version."** You tagged before bumping `MARKETING_VERSION`, or you
  mistyped the tag. Delete the tag, fix the cause, and tag again:
  ```bash
  git push --delete origin v0.14 && git tag -d v0.14
  ```
- **A test failed.** If it's flaky (this has happened once in CI), use **Re-run failed jobs**. If
  the draft already exists, the re-run replaces its assets (`gh release upload --clobber`) and keeps
  the notes. If the release was already published, the assets are still replaced and the run shows
  a warning.
- **You want a dry run without a tag.** Use Actions → Release → **Run workflow**, or
  `gh workflow run release.yml --ref main`. You get the artifact and no release.
- **You want to abandon the release.** Run `gh release delete v0.14 --yes --cleanup-tag`, then
  `git tag -d v0.14`.

## 4. Publish the draft

1. Open GitHub → **Releases** → the draft **MacMiniMixer v0.14**.
2. Download the zip in a browser on a Mac, check it with `shasum -a 256 -c …`, install it as in
   [section 5](#5-opening-an-ad-hoc-signed-build-end-users), and spot-check it.
3. Edit the notes if needed. Since the project is pre-1.0, consider ticking **Set as a
   pre-release**.
4. Click **Publish release**, or run `gh release edit v0.14 --draft=false`.
5. Afterwards, refresh `docs/HANDOFF.md` and start a new `## [Unreleased]` CHANGELOG section if it
   isn't there already.

## 5. Opening an ad-hoc-signed build (end users)

The build is not notarized, so Gatekeeper blocks the first launch of a downloaded copy.

1. Unzip `MacMiniMixer-<version>.zip` and move `MacMiniMixer.app` to `/Applications`.
2. Open it once, using one of these:
   - **macOS 13–14:** Control-click (right-click) the app → **Open** → **Open**.
   - **macOS 15 and later:** the right-click bypass no longer works. Double-click the app and
     dismiss the warning. Then go to **System Settings → Privacy & Security**, scroll to
     *Security*, click **Open Anyway** for MacMiniMixer, and confirm.
   - **Terminal (any version):**
     ```bash
     xattr -dr com.apple.quarantine /Applications/MacMiniMixer.app
     ```
3. Look for the icon in the **menu bar**. There is no Dock icon or window (`LSUIElement`).
4. macOS asks for **System Audio Recording** permission the first time a Process Tap feature runs.
   The permission is tied to the code signature, and every ad-hoc build has a different one. After
   an update, macOS may ask again, or the old entry may need to be removed and re-enabled under
   Privacy & Security.

## Future: Developer ID signing + notarization

**Documented only, not implemented.** With Developer ID signing and notarization, users get a
normal first launch with no Gatekeeper workaround. The app also gets a stable code identity, so the
System Audio Recording permission survives updates.

**Prerequisites**

- An Apple Developer Program membership.
- A **Developer ID Application** certificate, exported with its private key as a `.p12`.
- Notarization credentials. Use an App Store Connect API key (recommended for CI), or an Apple ID
  with an app-specific password and your Team ID.
- A real bundle identifier in place of `com.example.MacMiniMixer`. This is a `project.pbxproj`
  change and should get its own deliberate commit.
- Hardened runtime, which notarization requires. The app target already has
  `ENABLE_HARDENED_RUNTIME = YES`, and the commands below sign with `--options runtime`. There is no
  entitlements file today. Check on a notarized build that Process Tap capture still works under
  the hardened runtime. If it doesn't, an entitlements file may be needed, for example with
  `com.apple.security.device.audio-input`. This is unverified and must be tested.

**Steps** (replacing the ad-hoc signing in `scripts/package-app.sh`):

```bash
APP=MacMiniMixer.app
IDENTITY="Developer ID Application: <Name> (<TEAMID>)"

# 1. Sign with hardened runtime + secure timestamp. Avoid --deep for Developer ID: if nested code is
#    ever added (helpers, frameworks), sign it inside-out first. Add --entitlements <file> if needed.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# 2. Zip and notarize (blocks until Apple returns a verdict).
ditto -c -k --sequesterRsrc --keepParent "$APP" MacMiniMixer-0.14.zip
xcrun notarytool submit MacMiniMixer-0.14.zip \
  --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-UUID> \
  --wait
#   Apple ID alternative: --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
#   On "Invalid": xcrun notarytool log <submission-id> <same credentials>

# 3. Staple the ticket to the .app (a .zip can't be stapled), then re-zip the stapled app.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm MacMiniMixer-0.14.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" MacMiniMixer-0.14.zip
shasum -a 256 MacMiniMixer-0.14.zip > MacMiniMixer-0.14.zip.sha256

# 4. Gatekeeper should now accept it.
spctl --assess --type execute --verbose=4 "$APP"   # accepted, source=Notarized Developer ID
```

**Repository secrets for CI** (for the tag-only `Release` workflow; never expose them to PR
builds):

| Secret | Purpose |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | base64 of the Developer ID Application `.p12` (certificate + private key) |
| `MACOS_CERTIFICATE_PASSWORD` | password of that `.p12` |
| `MACOS_KEYCHAIN_PASSWORD` | password for a temporary CI keychain (any random string) |
| `MACOS_SIGNING_IDENTITY` | `Developer ID Application: <Name> (<TEAMID>)` (could also be a plain repository variable) |
| `NOTARY_API_KEY_P8_BASE64`, `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER_ID` | App Store Connect API key for `notarytool` (recommended) |
| *or* `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_APP_PASSWORD` | Apple ID alternative |

In CI, a few steps run before packaging:

1. Decode the `.p12`.
2. Create and unlock a temporary keychain (`security create-keychain`, `security unlock-keychain`).
3. Import the certificate into it (`security import … -T /usr/bin/codesign`).
4. Allow codesign to use the key (`security set-key-partition-list -S apple-tool:,apple:,codesign: -s`).
5. Add the keychain to the search list (`security list-keychains -d user -s …`).

Then sign, notarize, staple and re-zip as above, and delete the keychain in an `if: always()` step.
