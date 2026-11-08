# Releasing MacMiniMixer

Maintainer guide for packaging MacMiniMixer as a direct-download `.zip` and publishing it as a
GitHub Release.

> The protected workflow creates a draft after signing and notarization. Publish only after
> the maintainer approves the final draft.

## What gets shipped

- `MacMiniMixer-<version>.zip` contains the Developer ID signed and notarized Release app.
  It ships with `MacMiniMixer-<version>.zip.sha256` and build provenance.
- The app is **menu bar only**: `Info.plist` sets `LSUIElement`, so there is no Dock icon and no main
  window. The app lives in the menu bar and quits from **Quit MacMiniMixer** in the panel header's `⋯` menu.
- It runs on **macOS 13.0+**. Product Real Control and the other Process Tap features need
  **macOS 14.2+**. Product Real Control is **experimental**.
- The app bundle identifier is `com.akwnnwastaken.macminimixer` in Debug and Release.
  The previous `com.example.MacMiniMixer` defaults domain remains intact. Developer-only
  overrides do not migrate automatically; use the new domain for current instructions.

| Workflow | Trigger | Result |
| --- | --- | --- |
| `Build` → `package` job | pushes to `main` and manual (`workflow_dispatch`) runs, after the `build` job passes; docs-only changes skip CI | artifact `MacMiniMixer-app` (`MacMiniMixer-<version>-<sha7>.zip` + `.sha256`), kept 14 days |
| `macOS release candidate` | PR or manual dispatch without a tag | scans, tests, release build and staging artifact |
| `macOS release candidate` | dispatch on reviewed `main` with the exact existing tag | scans, tests, build, protected signing/notarization and verified draft |

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
      §3 app discovery, §4 Real App Control (always on, no toggle), §11 Stop / Stop All, §12 output-device change while
      active, §14 sleep/wake, and the §17/§18 Product Real smokes (steps that read the Advanced card need developer mode, see
      the checklist's setup). Audio must be normal after quitting,
      with no `sudo killall coreaudiod` needed.
- [ ] Verify the new `com.akwnnwastaken.macminimixer` identity with the **final signed build**:
      System Audio Recording request/denial/re-enable and Process Tap capture, plus Launch at
      Login registration, a real logout/login launch, and disabling it. Record results using
      the bundle-identity acceptance section in `docs/MANUAL_TEST_CHECKLIST.md`. Existing
      permissions and Login Items are not guaranteed to migrate; unsigned XCTest is not evidence
      for either behavior.
- [ ] `CHANGELOG.md` is final. Move the `[Unreleased]` entries into a new `## [vX.Y] - YYYY-MM-DD`
      section that opens with a short `### Highlights` list, and leave a new empty `## [Unreleased]`.
      `scripts/release-notes.sh` puts that Highlights list (or, without one, the whole section) into
      the release notes, followed by a link to the full changelog.
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
- [ ] `README.md` (the version in its status note and the zip name in "Installation") and
      `docs/HANDOFF.md` are ready to update after publication.
- [ ] The release commit is pushed and its `Build` run is green. That run's `MacMiniMixer-app`
      artifact is a good final smoke test.

## 2. Build a zip locally

```bash
scripts/package-app.sh                    # Release build → dist/MacMiniMixer-<version>.zip + .sha256
scripts/package-app.sh --skip-build       # reuse the existing ./.DerivedData-release Release build
scripts/package-app.sh --label rc1        # → dist/MacMiniMixer-<version>-rc1.zip
DIST_DIR=/tmp/mmm scripts/package-app.sh  # different output directory
```

The script does the following:

1. Builds with `xcodebuild build -configuration Release … CODE_SIGNING_ALLOWED=NO` into
   `./.DerivedData-release` (kept separate from the test build so code-coverage instrumentation never reaches the shipped binary).
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

## 3. Prepare and review the draft

Use the [protected macOS release runbook](MACOS-RELEASE.md). Push the matching version tag
straight from the approved commit to create a lightweight tag without a tagger email, then
dispatch the workflow on `main`. Existing releases and drafts are never changed by the workflow.

Download the new draft ZIP in a browser on a clean Mac and verify the checksum. Unzip and
move the app to Applications. Run the final signed-build checks in section 1, including
System Audio Recording, audio recovery and Launch at Login. After explicit maintainer approval,
publish the draft in GitHub and update the README and handoff. The local ad hoc ZIP is for
development testing only.
