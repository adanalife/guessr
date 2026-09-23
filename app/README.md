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
`DEVELOPMENT_TEAM=<team id>` before `xcodegen`.

## Build settings

Two settings are empty in a public checkout, declared in `Guessr.xcconfig`:

| Setting | Empty means |
|---|---|
| `GUESSR_TWITCH_CLIENT_ID` | the Twitch login is switched off |
| `GUESSR_OWNER_TWITCH_ID` | nobody is the owner |

Set them in `Local.xcconfig` beside it (gitignored), or pass them to
`xcodebuild` as `NAME=value`. The owner id is the numeric Twitch user id,
never the login, which can be renamed.

## The console tier

The app can also link `TempomatConsole`, a private package that adds the
owner's controls to Settings when the signed-in Twitch user is the owner. The
code sits behind `#if canImport(TempomatConsole)`, so a build without access to
the package (a fork, say) deletes the `TempomatConsole` package block and its
dependency line from `project.yml`, and gets the game without it. CI does
exactly that when it has no token to fetch the package.
