# Changelog

What changed in the game, release by release. Newest first.

<!-- towncrier release notes start -->

## v1.1.0 — 2026-08-07

### Changed

- The stream preview in the last cell of the end-of-game board actually plays now. It had never once worked — YouTube would not tell the game which video was live, so the cell always fell back to being a plain link. It finds the current broadcast a different way now, and keeps finding it on its own every time a new stream starts. ([#93](https://github.com/adanalife/guessr/pull/93))
- Rounds are now chosen from every moment the dashcam recorded a position for, rather than only the moments that happen to have a visual fingerprint on file — about three times as many per clip to pick the best of. The answer is also read from the exact moment the round is cut at, so the circle it is drawn in is tighter. ([#96](https://github.com/adanalife/guessr/pull/96))
- On a phone the end-of-game board puts the live stream preview first, instead of six tiles down. ([#106](https://github.com/adanalife/guessr/pull/106))
- Round selection weighs distinctiveness once, in the ranking, instead of also cutting a fixed slice of the pool beforehand. ([#107](https://github.com/adanalife/guessr/pull/107))

### Fixed

- `task stats:prod` reports the number of players who finished a day, rather than five times it. ([#108](https://github.com/adanalife/guessr/pull/108))

### Behind the scenes

- New releases are announced in Discord now, so there is somewhere to hear that the game changed without watching this file. A release that fails to deploy raises an alert in a separate channel, which nothing said out loud before. ([#54](https://github.com/adanalife/guessr/pull/54))
- Publishing a new set of rounds is now one command that does every step in the right order, instead of several that had to be remembered in the right order. ([#65](https://github.com/adanalife/guessr/pull/65))
- Future rounds are answered with the coordinate the dashcam printed on the frame you were shown, instead of one averaged over the whole three minutes of footage it was cut from. The answer used to land a mile or so up the road from the street in the clip; now it lands on it. Rounds already in the game are unchanged — this applies to the next batch built. ([#81](https://github.com/adanalife/guessr/pull/81))
- Round footage now streams straight from storage instead of being copied out with every update of the site. Nothing changes about how a round looks or plays — but updates ship in seconds rather than minutes, and your browser can now hold onto a clip it has already seen. ([#82](https://github.com/adanalife/guessr/pull/82))
- The daily rounds are now scheduled ahead of time rather than drawn fresh each day, which means you will never be shown a round you have already played. Practice rounds are drawn only from days that have finished, so they can no longer spoil an upcoming game. ([#83](https://github.com/adanalife/guessr/pull/83))
- The game's database structure is now managed as numbered migrations, so each environment records what it has applied and can be checked rather than guessed at. Nothing changes about how the game plays. ([#84](https://github.com/adanalife/guessr/pull/84))
- The leaderboards now look up each player's name directly instead of searching the whole play history for it once per row. The boards are fetched constantly to feed the overlay on stream, so that search was reading millions of rows a day out of a table holding a few hundred. ([#94](https://github.com/adanalife/guessr/pull/94))
- Upcoming days can now be watched through before they go live, so a clip that turns out to be unguessable or a pin in the wrong street gets caught off the test site rather than on the day itself. ([#97](https://github.com/adanalife/guessr/pull/97))
- Scores and answers can now be dumped to a file before anything risky is done to the database they live in, so a bad change has somewhere to be restored from. Nothing changes about how the game plays. ([#98](https://github.com/adanalife/guessr/pull/98))
- The check that makes sure a round's footage has the dashcam's on-screen coordinates cropped off no longer reports a false alarm when a freshly-uploaded clip arrives incomplete — it waits for the whole file, and if it still cannot read it, says so plainly instead of blaming the crop. ([#99](https://github.com/adanalife/guessr/pull/99))
- A round that turns out to be a dud — a tunnel, a blank stretch of highway, coordinates that land in a river — can now be thrown out of an upcoming day before anyone plays it, and is replaced automatically. Days already in progress are never touched. ([#100](https://github.com/adanalife/guessr/pull/100))
- The day preview now says which part of the world a day is currently being played in, rather than just that it is open, so it is obvious at a glance whether a problem can still be fixed. ([#102](https://github.com/adanalife/guessr/pull/102))
- Groundwork for a change to how the game stores its daily rounds: the days already in progress when the switch happens will play exactly the clips they would have anyway, so a game you are halfway through will not change under you. ([#102](https://github.com/adanalife/guessr/pull/102))
- Round generation reads its encoder thread count from a `THREADS` environment variable again, so the scheduled in-cluster run can pin it to the pod's CPU limit. Unset, the laptop default (half the cores) is unchanged. ([#103](https://github.com/adanalife/guessr/pull/103))
- The page used to review upcoming days now draws a map of every round the game could pick from, with the day being reviewed marked on it — so the part of the country the clips come from is visible at a glance rather than read off a list of state names. ([#104](https://github.com/adanalife/guessr/pull/104))
- The page used to review upcoming days now reads like the game itself — the same typeface and colours, and it follows the light or dark setting chosen on the game. ([#104](https://github.com/adanalife/guessr/pull/104))

## v1.0.1 — 2026-08-03

### New

- The empty sixth square on the end-of-game board now holds the live stream the footage comes from, playing muted alongside the five clips you just guessed. When the stream is off it is a plain link instead. ([#76](https://github.com/adanalife/guessr/pull/76))

### Fixed

- The five clips on the end-of-game board are clickable again. Tapping one puts it back on screen at full size, so you can replay it and zoom in on whatever you missed; Escape brings you back to all five. This was most obvious after a reload, where the tiles did nothing at all. ([#76](https://github.com/adanalife/guessr/pull/76))

### Behind the scenes

- The dashcam prints where it is along the bottom of every frame, and that strip gets cut off before a round is built from it. Each release now re-checks that on the footage it has just published, so a batch that slipped through uncropped is caught before anyone plays a round with the answer written across it. ([#66](https://github.com/adanalife/guessr/pull/66))
- No change to the game. The write-up of how rounds get picked lived in two places and had already started to disagree with itself; there is one copy of it now. ([#70](https://github.com/adanalife/guessr/pull/70))
- The test that backs the crop check was quietly skipping itself in the automated checks. It runs now, and refuses to be skipped there again. ([#72](https://github.com/adanalife/guessr/pull/72))
- The share string — the coloured squares, the total, and the link back to the game — is now covered by tests, so a result you paste keeps saying what it should. ([#74](https://github.com/adanalife/guessr/pull/74))
- Linking a device to itself — scanning your own code on the phone that drew it — is now covered by a test, so it stays the harmless no-op it is meant to be rather than something that could clear your history. ([#74](https://github.com/adanalife/guessr/pull/74))
- The checks that stop a bad round set reaching the game — a clip with the location still printed on it, or a round whose answer was accidentally sent to your browser — are now tested themselves, so they cannot quietly stop working. ([#74](https://github.com/adanalife/guessr/pull/74))
- A release now waits for the new set of rounds to actually reach the site before it checks them over. The v1.0.0 release was reported as a failure because those checks read the previous set of rounds while the new one was already live — the game was fine, and the report was wrong about it. ([#75](https://github.com/adanalife/guessr/pull/75))
- Running the game locally from a clean checkout works again — its two database setup steps were racing each other and leaving the database in a state the game refused to start against. ([#77](https://github.com/adanalife/guessr/pull/77))

## v1.0.0 — 2026-08-03

Rounds move now. Every one of them is a few seconds of the road going past instead of a single frozen frame, which is how the footage looked from the driver's seat in the first place.

### New

- Play on your phone and your laptop and it counts as one player. Scan the code from one device on the other, and everything either of them has scored ends up under a single name on the board. ([#52](https://github.com/adanalife/guessr/pull/52))
- You can pause a round to study it — the button sits with the zoom controls, and the space bar does the same thing. A round you pause stays paused for the rest of the game. ([#53](https://github.com/adanalife/guessr/pull/53))

### Changed

- Every round is now a few seconds of moving footage instead of a single frozen frame. The road goes past, and how things shift against each other is another clue about where you are. ([#53](https://github.com/adanalife/guessr/pull/53))
- The header no longer announces how hard a round is. On a phone it was pushing the other stats onto a second line and taking room the footage wants. A game still ramps from easier to harder as you play it — it just doesn't say so. ([#56](https://github.com/adanalife/guessr/pull/56))
- Rounds are drawn from further apart. The old set kept coming back to the same handful of well-driven roads — half of it sat within a few kilometres of another round, and a third of it was California. A day now spans more of the country, and more states show up at all. ([#58](https://github.com/adanalife/guessr/pull/58))
- Rounds are picked from several moments of each stretch of driving rather than one moment chosen at random, so a round is less likely to open on glare, on a truck filling the windscreen, or on a frame that is mostly sky. ([#63](https://github.com/adanalife/guessr/pull/63))
- The intro and the About panel say things more plainly, and point at the stream in one place instead of three. ([#67](https://github.com/adanalife/guessr/pull/67))
- The code for linking a second device no longer sits in a bright white square — it takes the panel's own colours now, dark or light. ([#67](https://github.com/adanalife/guessr/pull/67))

### Behind the scenes

- Tapping the version number in the About panel now leads to a changelog written for players, instead of a list of commit subjects. ([#57](https://github.com/adanalife/guessr/pull/57))
- Building a new set of rounds is faster to get right: the picking can be tried out on its own without cutting any footage, and a round whose clip comes out empty is re-cut rather than sinking the whole batch. ([#58](https://github.com/adanalife/guessr/pull/58))
- A new version is now checked against itself once it goes out, rather than against whichever version happened to still be answering — so an update no longer gets reported as broken when it was fine. And putting an older version back works the same way as shipping a new one, instead of having to be done by hand. ([#62](https://github.com/adanalife/guessr/pull/62))
- Building a new set of rounds no longer has to happen on a laptop, which is a step towards new rounds arriving on their own rather than when someone remembers to make them. ([#64](https://github.com/adanalife/guessr/pull/64))
- The check that stops a round shipping with the dashcam's location readout still printed across it now measures the footage with the same tool that cut it, instead of a hand-written reader kept alongside. Same guarantee, a lot less to go wrong in. ([#68](https://github.com/adanalife/guessr/pull/68))
- Nothing changes about how a round looks. The settings that decide how the footage is compressed are now written down in one place rather than passed in every time, which makes them harder to change by accident. ([#69](https://github.com/adanalife/guessr/pull/69))
- A little dead weight gone: a check that ran twice over the same round set, and a line in the page that could never do anything. ([#71](https://github.com/adanalife/guessr/pull/71))

## [0.8.0](https://github.com/adanalife/guessr/compare/v0.7.0...v0.8.0) (2026-08-02)


### Features

* **api:** show each player's current alias, and number the duplicates ([#49](https://github.com/adanalife/guessr/issues/49)) ([3d6fdeb](https://github.com/adanalife/guessr/commit/3d6fdeb18a3f9a7aa6f97cf1688dd5094d4187bd))

## [0.7.0](https://github.com/adanalife/guessr/compare/v0.6.0...v0.7.0) (2026-08-02)


### Features

* **api:** serve the daily and monthly boards ([#43](https://github.com/adanalife/guessr/issues/43)) ([b69dcf3](https://github.com/adanalife/guessr/commit/b69dcf36a60f9d7f4ad091d3e45004b975f0c57a))
* **score:** verify a daily play against that date's draw and window ([#42](https://github.com/adanalife/guessr/issues/42)) ([d28c646](https://github.com/adanalife/guessr/commit/d28c6463591b30bdf5b0a9687e0940c9ad0a0660))
* **web:** play under a generated two-word alias ([#45](https://github.com/adanalife/guessr/issues/45)) ([f357c40](https://github.com/adanalife/guessr/commit/f357c402d02688f1edd140189327c017dbf076bb))
* **web:** take the blog's ET Book type and light/dark palette ([#46](https://github.com/adanalife/guessr/issues/46)) ([a5937ca](https://github.com/adanalife/guessr/commit/a5937ca6faef156d9986868d6fdcadf0e928bf0b))

## [0.6.0](https://github.com/adanalife/guessr/compare/v0.5.1...v0.6.0) (2026-08-01)


### Features

* **score:** record one daily result per player per round ([#38](https://github.com/adanalife/guessr/issues/38)) ([a37323b](https://github.com/adanalife/guessr/commit/a37323b445fe8d73f9b519e2f5dfce2ef1cb06ec))
* **web:** give the frame the whole pane, the map a corner minimap ([#39](https://github.com/adanalife/guessr/issues/39)) ([eae171c](https://github.com/adanalife/guessr/commit/eae171c519556f5e9f446e11f5284a5df572e9f2))
* **web:** name guessr.dana.lol as the canonical URL ([#40](https://github.com/adanalife/guessr/issues/40)) ([3120c4a](https://github.com/adanalife/guessr/commit/3120c4a1cde20178b2e07c0bea992f99e87fb9ea))

## [0.5.1](https://github.com/adanalife/guessr/compare/v0.5.0...v0.5.1) (2026-08-01)


### Bug Fixes

* **daily:** stop a backwards clock re-opening a played-out day ([#35](https://github.com/adanalife/guessr/issues/35)) ([c1dad83](https://github.com/adanalife/guessr/commit/c1dad83f0013b9ffdef1778a72792bcc8e7ed840))
* **web:** pan the zoomed frame on Firefox ([#34](https://github.com/adanalife/guessr/issues/34)) ([e1841aa](https://github.com/adanalife/guessr/commit/e1841aa2af3d3625463f386ae7ae2ad6fb7fb0a9))

## [0.5.0](https://github.com/adanalife/guessr/compare/v0.4.0...v0.5.0) (2026-08-01)


### Features

* score guesses server-side so the answers never reach the browser ([#31](https://github.com/adanalife/guessr/issues/31)) ([71397b1](https://github.com/adanalife/guessr/commit/71397b111953b41be720e5c2d32592cd21a1538a))
* **web:** map every round at the end of a game, and every round ever ([#26](https://github.com/adanalife/guessr/issues/26)) ([c91b496](https://github.com/adanalife/guessr/commit/c91b496089c2ce5654447520349533f01a7bd83c))


### Bug Fixes

* **daily:** save progress every round so a reload resumes ([#32](https://github.com/adanalife/guessr/issues/32)) ([164cce0](https://github.com/adanalife/guessr/commit/164cce0cb8e0aaed1a7b4f275ffdc31d2c398b07))

## [0.4.0](https://github.com/adanalife/guessr/compare/v0.3.0...v0.4.0) (2026-08-01)


### Features

* **web:** add a web app manifest ([#29](https://github.com/adanalife/guessr/issues/29)) ([d663875](https://github.com/adanalife/guessr/commit/d663875585bfa0a5ab02fdee3c226c400e754e56))
* **web:** add an apple-touch-icon and badge the share card ([#27](https://github.com/adanalife/guessr/issues/27)) ([255d12c](https://github.com/adanalife/guessr/commit/255d12cee72648bdccb0706979dddd9802bc8a98))
* **web:** add platform icons to the About panel links ([#30](https://github.com/adanalife/guessr/issues/30)) ([2fb6130](https://github.com/adanalife/guessr/commit/2fb6130a3e24c7feca10e27d39132db7698eeeec))

## [0.3.0](https://github.com/adanalife/guessr/compare/v0.2.0...v0.3.0) (2026-08-01)


### Features

* **ci:** deploy a preview for every pull request ([#16](https://github.com/adanalife/guessr/issues/16)) ([d0e29cf](https://github.com/adanalife/guessr/commit/d0e29cf7e51c8df0907625e1080bcb5dcd4a432b))
* **ci:** stage/prod deploy tiers, with the version and changelog on the page ([#13](https://github.com/adanalife/guessr/issues/13)) ([3e2f5df](https://github.com/adanalife/guessr/commit/3e2f5dfe0d88cd52f694728bfc7c1dd90b65f730))
* **web:** add a reset for saved state outside production ([#23](https://github.com/adanalife/guessr/issues/23)) ([93f889b](https://github.com/adanalife/guessr/commit/93f889bb6da412b5ab81a701912cf0f1002c6230))
* **web:** add zoom buttons to the frame pane ([#19](https://github.com/adanalife/guessr/issues/19)) ([0691b5c](https://github.com/adanalife/guessr/commit/0691b5c3230d6b7369f8c67cf3b7f040321315a8))
* **web:** blend the adanalife mark into the favicon pin ([#24](https://github.com/adanalife/guessr/issues/24)) ([1599dae](https://github.com/adanalife/guessr/commit/1599dae2650f1583daec7da78c8e4a94594283a3))
* **web:** link the YouTube stream from the About panel ([#12](https://github.com/adanalife/guessr/issues/12)) ([883d25d](https://github.com/adanalife/guessr/commit/883d25dab105144f78551689e880ebb56c199f1d))
* **web:** ramp each game easy to hard and show difficulty ([#18](https://github.com/adanalife/guessr/issues/18)) ([1c3daff](https://github.com/adanalife/guessr/commit/1c3daff68a2e3921b5b3dd4e9cc084947d27e407))
* **web:** simplify the intro copy ([#25](https://github.com/adanalife/guessr/issues/25)) ([ba6a3c7](https://github.com/adanalife/guessr/commit/ba6a3c7a4c786e296ea27f31f3f07a9254d804c4))
* **web:** welcome players with a dismissible intro, and link the changelog ([#20](https://github.com/adanalife/guessr/issues/20)) ([e5fc4ee](https://github.com/adanalife/guessr/commit/e5fc4eeb5e232373a15c8c4a8fbc5d0a52228c35))


### Bug Fixes

* **ci:** queue staging deploys instead of cancelling them ([#22](https://github.com/adanalife/guessr/issues/22)) ([c0cd117](https://github.com/adanalife/guessr/commit/c0cd1178e39148a794b442b14d597035e07c3a48))
* **rounds:** make --seed reproduce the pool draw ([#17](https://github.com/adanalife/guessr/issues/17)) ([fa29f0d](https://github.com/adanalife/guessr/commit/fa29f0de9fe4bb41c6f2c24cd0488819f4102b8c))
* **web:** drop the footage byline from the about toggle ([#21](https://github.com/adanalife/guessr/issues/21)) ([e49786b](https://github.com/adanalife/guessr/commit/e49786b25aa811ef971d7bb00a8e54e2e97ba29c))


### Performance Improvements

* **ci:** read frame dimensions from the JPEG header, not ffprobe ([#15](https://github.com/adanalife/guessr/issues/15)) ([9fc900d](https://github.com/adanalife/guessr/commit/9fc900d73bfc32aae788bd393a6f7e1ccf37f073))

## [0.2.0](https://github.com/adanalife/guessr/compare/v0.1.0...v0.2.0) (2026-08-01)


### Features

* add a daily round with a spoiler-free share string ([#2](https://github.com/adanalife/guessr/issues/2)) ([af46a73](https://github.com/adanalife/guessr/commit/af46a73cade3107c40134b0a5e1ab1a975f6eb74))
* **ci:** deploy to Cloudflare Pages on every merge to main ([#6](https://github.com/adanalife/guessr/issues/6)) ([5a31467](https://github.com/adanalife/guessr/commit/5a3146703998a4551859043fcfe8f89963ff0cfc))
* pick rounds by locatability instead of sampling uniformly ([3707492](https://github.com/adanalife/guessr/commit/370749237fd9a9150b450966cf9ecf0f1c4b5392))
* playable prototype of the dashcam guessing game ([8b99f76](https://github.com/adanalife/guessr/commit/8b99f76af44d51e17fa9ae8a9ba6b9c04f3ab231))
* **rounds:** drop visually generic clips using mean cosine distance ([#5](https://github.com/adanalife/guessr/issues/5)) ([75be227](https://github.com/adanalife/guessr/commit/75be22791eb16bd07f8209d1dcb683f9c90be595))
* **web:** add a collapsible About panel ([#11](https://github.com/adanalife/guessr/issues/11)) ([9dce515](https://github.com/adanalife/guessr/commit/9dce515697a84d47a17ed433b9cf809519c7f6d9))
* **web:** add a link preview card and favicon ([#4](https://github.com/adanalife/guessr/issues/4)) ([9ced812](https://github.com/adanalife/guessr/commit/9ced81248231229dc086a53c4acaef4ada9889b6))
* **web:** let players zoom and pan the frame ([#10](https://github.com/adanalife/guessr/issues/10)) ([3124613](https://github.com/adanalife/guessr/commit/312461351b16cbc6019a30168ee135e8691fda02))


### Bug Fixes

* **rounds:** stage a generation and swap it in only once it passes check ([#7](https://github.com/adanalife/guessr/issues/7)) ([b41810a](https://github.com/adanalife/guessr/commit/b41810abe1834540e3b8defe24189c9fcb7e3e0d))
* **web:** pin the share string to guessr.dana.lol ([#9](https://github.com/adanalife/guessr/issues/9)) ([f5acfbb](https://github.com/adanalife/guessr/commit/f5acfbbea68d183b94bde3f1abb8d79b416baf9c))
