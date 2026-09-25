# Guessr for iOS

A SwiftUI app over the game's public API. `GuessrKit/` holds everything that
needs no UI (the API client and the Twitch login) and tests on its own with
`swift test`.

## Build

```sh
brew install xcodegen
cd app
xcodegen            # writes Guessr.xcodeproj from project.yml
open Guessr.xcodeproj
```

Run the `Guessr` scheme on a simulator. For a device, export
`DEVELOPMENT_TEAM=<team id>` before `xcodegen`. `task ios:build` does the
simulator build from the repo root.

## TestFlight

The app's version is the repo's release tag: the `vX.Y.Z` release-please cuts
for the web game is the version TestFlight shows, and the build number is the
commit count. `task ios:release` builds only from a clean checkout of a tag,
then archives, uploads and waits for Apple to finish processing:

```sh
git fetch --tags && git checkout vX.Y.Z
task ios:release
```

It reads four variables from the environment:

| Variable | What |
|---|---|
| `DEVELOPMENT_TEAM` | the Apple Developer team id |
| `ASC_KEY_PATH` | the App Store Connect API key (`.p8`), kept outside the repo |
| `ASC_KEY_ID` | that key's id |
| `ASC_ISSUER_ID` | the key's issuer id |

Signing needs the team's *Apple Distribution* certificate in the keychain and an
App Store profile for `lol.dana.guessr` named `Guessr App Store`.
`task ios:archive` and `task ios:upload` are the two halves, for a deliberate
off-tag build or a retried upload; `task ios:verify` asks App Store Connect
whether the newest tag has an installable build.

## Build settings

Two settings are empty in a public checkout, declared in `Guessr.xcconfig`:

| Setting | Empty means |
|---|---|
| `GUESSR_TWITCH_CLIENT_ID` | the Twitch login is switched off |
| `GUESSR_OWNER_TWITCH_ID` | nobody is the owner |

Set them in `Local.xcconfig` beside it (gitignored), or pass them to
`xcodebuild` as `NAME=value`. The owner id is the numeric Twitch user id,
never the login, which can be renamed. `task ios:upload` refuses an archive
whose client id is empty, so a TestFlight build always has the login on.

`GUESSR_TWITCH_CHANNEL` is set in the tree: the Chat tab talks in `adanalife_`
in a Release build and in `adanalife_staging` in a Debug one.

## The console tier

The app can also link `TempomatConsole`, a private package that adds the
owner's controls to Settings when the signed-in Twitch user is the owner. The
code sits behind `#if canImport(TempomatConsole)`, so a build without access to
the package (a fork, say) deletes the `TempomatConsole` package block and its
dependency line from `project.yml`, and gets the game without it. CI does
exactly that when it has no token to fetch the package.
