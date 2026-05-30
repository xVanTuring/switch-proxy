# Release & Notarization

`scripts/release.sh` produces a signed, **notarized** build and publishes a
GitHub release with both a `.zip` and a `.dmg`.

```bash
./scripts/release.sh 1.0.0                 # full release
./scripts/release.sh 1.0.0 --dry-run       # bump + Debug build + local commit only
./scripts/release.sh 1.1.0 --prerelease beta
./scripts/release.sh 1.0.0 --notes-file NOTES.md
```

The script bumps `CFBundleShortVersionString` (to the given version) and
`CFBundleVersion` (auto-incremented) in `project.yml`, regenerates the Xcode
project, verifies a Debug build, commits, then archives **Release**
(Developer ID + hardened runtime), notarizes, staples, builds the DMG, tags,
and creates the GitHub release.

## One-time machine setup

1. **Developer ID Application certificate** for the team in your keychain
   (default team `T8F5T6HKG8`):
   Xcode → Settings → Accounts → Manage Certificates → **+** → *Developer ID Application*.

2. **notarytool credentials** stored under a keychain profile (default name
   `noticky-notary`, shared with the Noticky project — it is account-level and
   works for any app under the same Apple ID):

   ```bash
   xcrun notarytool store-credentials noticky-notary \
     --apple-id "<your-apple-id>" \
     --team-id T8F5T6HKG8 \
     --password "<app-specific-password>"
   ```

   An app-specific password is created at <https://appleid.apple.com> → Sign-In
   and Security → App-Specific Passwords.

3. **gh** authenticated (`gh auth login`) with `repo` scope.

## Overrides

- `TEAM_ID=<id> ./scripts/release.sh ...` — different Apple Developer team.
- `NOTARY_PROFILE=<name> ./scripts/release.sh ...` — different notary profile.

## Notes

- The Xcode project (`SwitchProxy.xcodeproj`) is gitignored; the script runs
  `xcodegen` to (re)generate it from `project.yml`.
- The app icon is generated from `icon/AppIcon.svg` by `scripts/make-icon.sh`
  into `Sources/Assets.xcassets/AppIcon.appiconset` (committed, so a fresh
  clone builds without re-rendering). Re-run that script after editing the SVG.
- App is **not** sandboxed (it runs `networksetup` / `osascript` and opens a
  local listener). Developer ID + notarization does not require sandboxing.
