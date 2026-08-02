# Changelog

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
