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
then archives, uploads, waits for Apple to finish processing, and sends the
build's dSYMs to Sentry:

```sh
git fetch --tags && git checkout vX.Y.Z
task ios:release
```

It reads four variables from the environment:

| Variable | What |
| --- | --- |
| `DEVELOPMENT_TEAM` | the Apple Developer team id |
| `ASC_KEY_PATH` | the App Store Connect API key (`.p8`), kept outside the repo |
| `ASC_KEY_ID` | that key's id |
| `ASC_ISSUER_ID` | the key's issuer id |

The dSYM upload (`task ios:dsyms`, the release's last step) authenticates with
a Sentry org token (scope `org:ci`). It reads `SENTRY_AUTH_TOKEN` if set, and
otherwise fetches `/release/sentry-org-token` from the prod account's SSM
through `aws-vault`. Seed that once with:

```sh
aws-vault exec adanalife-prod -- aws ssm put-parameter \
  --name /release/sentry-org-token --type SecureString --overwrite --value '<token>'
```

Signing needs the team's *Apple Distribution* certificate in the keychain and an
App Store profile for `lol.dana.guessr` named `Guessr App Store`.
`task ios:archive` and `task ios:upload` are the two halves, for a deliberate
off-tag build or a retried upload; `task ios:validate`, which the release runs
between them, puts the last archive through the App Store export checks
without uploading it; `task ios:verify` asks App Store Connect
whether the newest tag has an installable build.

## Universal links

The website's *Link a device* QR code (`web/link.js`) opens the app when it is
installed, and Safari otherwise. Three parts agree on it: the site serves
`web/.well-known/apple-app-site-association`, which names the team and bundle
id and matches only the site root carrying `#link=` (the `_headers` rule beside
it gives the extensionless file its JSON content type); the app's entitlements
in `project.yml` name `guessr.dana.lol` and its stage; and `GuessrApp`'s
`onOpenURL` reads the player out of the fragment (`DeviceLink` in GuessrKit)
and runs the same `POST /api/link` merge the website does, behind a question.

The App ID in the developer portal needs the *Associated Domains* capability,
and the `Guessr App Store` profile has to be regenerated after it is added; a
build signed with a profile that lacks it installs, and iOS quietly never hands
it a link. Apple's CDN fetches the file on install, not on every scan, so after
a change check what it holds:

```sh
curl https://app-site-association.cdn-apple.com/a/v1/guessr.dana.lol
```

A fresh install, or Settings → Developer → *Associated Domains Development* →
*Diagnostics* on a device, says what iOS resolved the domain to.

## Game Center

The app signs its player into Game Center and shows the dashboard from
Settings. Scores and achievements never leave the device: the app tells the
server which Game Center player it is (`POST /api/gamecenter`), and the server
submits what its `plays` table says that player has earned, through the App
Store Connect API. A modified app can therefore claim nothing the game did not
record.

Game Center is configured in App Store Connect, under the app's Game Center
tab, with these identifiers (`server/gamecenter.py` is where they live in code).
`task gamecenter:config` plans what is missing there and `-- --apply` creates
it, English localization included, through the App Store Connect API with the
same key as the release. `task gamecenter:images` renders each achievement's
image from the game's mark and palette, which the next `--apply` uploads
wherever an achievement has none:

| Identifier | Kind | What |
| --- | --- | --- |
| `lol.dana.guessr.lifetime` | classic leaderboard, best score, integer | every point ever |
| `lol.dana.guessr.weekly` | recurring leaderboard, 7 days from Monday 00:00 UTC, best score, integer | the ISO week's points |
| `lol.dana.guessr.first_pin` | achievement | a first round played |
| `lol.dana.guessr.bullseye` | achievement | a guess inside 5 miles |
| `lol.dana.guessr.golden_day` | achievement | five rounds in a day totaling 20,000 |
| `lol.dana.guessr.week_streak` | achievement, progressive | seven days in a row |
| `lol.dana.guessr.century` | achievement, progressive | a hundred rounds |
| `lol.dana.guessr.perfect_round` | achievement | 5,000 on a round |
| `lol.dana.guessr.perfect_day` | achievement | 5,000 on all five rounds of a day |
| `lol.dana.guessr.top_ten` | achievement | a finished month in the game's monthly board's top ten |

The second board is a week, not the game's month: a Game Center recurring
leaderboard runs at most 30 days, recurs only by minutes, hours or days, and
may not overlap, so a calendar month cannot be expressed.

Whether an achievement is browsable before it is earned, or hidden until then,
is the per-achievement *Hidden* setting in App Store Connect, not anything in
code.

The server submits only where the Worker has the App Store Connect key, set as
three secrets; a tier without them (stage) accepts the sync and submits
nothing, which is also why a Debug build pointed at stage never reaches the
boards:

```sh
wrangler secret put ASC_KEY_ID --env production      # the key's id
wrangler secret put ASC_ISSUER_ID --env production   # the issuer id
wrangler secret put ASC_PRIVATE_KEY --env production # the .p8, pasted whole
```

The key needs a role that may write Game Center data (App Manager or Admin).
The submissions name the prerelease configuration while the app lives on
TestFlight; `PRERELEASED` in `server/gamecenter.py` flips when it ships.

## App Store

The listing lives in `store.toml` beside this file: the name, subtitle,
privacy policy and category, the version's description, keywords and URLs,
the review notes and the age-rating declaration. `task asc:listing` reads App
Store Connect back and prints what differs; `task asc:listing -- --apply`
writes it, with the same key as the release. It creates the version named at
the top of the file when none is editable, attaches the newest valid
TestFlight build of that version once there is one, and uploads screenshots
from `.build/screenshots` wherever App Store Connect has none for a display
type. The review contact and the demo account are not public: they go in
`store.local.toml` (gitignored), merged over `store.toml` table by table:

```toml
[review]
contact_last_name = "…"
contact_phone = "+1 …"
contact_email = "…"
demo_account_name = "…"      # a review-only Twitch login, a plain viewer
demo_account_password = "…"
```

`task ios:screenshots` takes the screenshots: it builds for the simulator,
then on an iPhone 17 Pro Max and a 13-inch iPad Pro launches the Debug build
with its launch arguments (`-tab`, `-autoplay 1`) and captures a
round, its reveal and Settings, with Apple's 9:41 status bar. The
Debug build plays stage, so the round is staging's.

Two things the API does not do, and the dashboard does: the App Privacy
labels (they must agree with `Guessr/PrivacyInfo.xcprivacy`), and the
submission itself, which is the *Add for Review* button on the version.
Submitting a version that reaches *Pending Developer Release* and releasing it
by hand is the point of `release_type = "MANUAL"`: the server's
`PRERELEASED` flag has to flip in the same minute (see Game Center above).

## Build settings

Two settings are empty in a public checkout, declared in `Guessr.xcconfig`:

| Setting | Empty means |
| --- | --- |
| `GUESSR_TWITCH_CLIENT_ID` | the Twitch login is switched off |
| `GUESSR_OWNER_TWITCH_ID` | nobody is the owner |

Set them in `Local.xcconfig` beside it (gitignored), or pass them to
`xcodebuild` as `NAME=value`. The owner id is the numeric Twitch user id,
never the login, which can be renamed. `task ios:upload` refuses an archive
whose client id is empty, so a TestFlight build always has the login on.

`GUESSR_TWITCH_CHANNEL` is set in the tree: the Chat tab talks in, and the Watch
tab watches, `adanalife_` in a Release build and `adanalife_staging` in a Debug one.

## Languages

The app follows the device language, or the one picked for it under iOS
Settings › Guessr › Language: English, French, Spanish, Russian and Czech. Every string lives in a catalog, `Guessr/Localizable.xcstrings` for the
app, `GuessrKit/Sources/GuessrKit/Localizable.xcstrings` for the package, and
`Guessr/AppShortcuts.xcstrings` for the Siri phrases. A string literal in a
SwiftUI view localizes on its own; one built as a `String` goes through
`String(localized:)`, and the package's strings name `bundle: .module`, since
SwiftUI looks in the app bundle otherwise. The build extracts every literal it
finds (`SWIFT_EMIT_LOC_STRINGS`), so a new string shows up in the catalog the
next time the project is built in Xcode, waiting for its translations.

## The console tier

The app can also link `TempomatConsole`, a private package that adds the
owner's controls to Settings when the signed-in Twitch user is the owner. The
code sits behind `#if canImport(TempomatConsole)`, so a build without access to
the package (a fork, say) deletes the `TempomatConsole` package block and its
dependency line from `project.yml`, and gets the game without it. CI does
exactly that when it has no token to fetch the package.
