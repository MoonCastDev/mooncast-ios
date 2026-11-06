# MoonCast for iPad and iPhone: parity with Android

This file used to keep a feature table by hand, and it fell behind the code (for example it said there was no
identity transfer and no deadzone or motion setting, though all three were in the app). The current comparison is
the code-level review of 2026-11-03, with file and line evidence for every row:

- `workspace/reports/2026-11-03-mooncast-android-vs-ios.md` (Android `feat/auto-bitrate` e1977c9a against iOS
  `feat/pyrowave`), sections 2 (features by area), 3a (what to port or fix on iOS) and 4 (exact values).

Since that review, on `feat/pyrowave`:

- Picture in picture works in Release builds too (it was set up only in Debug builds); PyroWave and Super resolution
  streams still have none.
- Automatic bitrate follows the design (docs/auto-bitrate-design.md, MoonCastDev/moonlight-android#139) with
  Android's values where the design gives none: floor 5 Mbps at 720p60, any loss is "strained", any frame FEC gave
  up on is "congested", RTT rising over its lowest by max(15 ms, that lowest), a good minute needs 40% of the rate
  arriving and 100 packets a second, step-ups +20% (at least 1 Mbps) with a back-off kept per network, budgets
  2 reconnects a minute and 1 for step-ups, a suggestion at most every 2 minutes, a memory of 64 entries with
  away streams kept per place, and Polaris's live bitrate in encoder units. A step-up only raises the remembered
  limit once it has held for a minute.
- moonlight-common-c no longer counts packets it dropped itself (an old frame's FEC shards, runts, failed
  decryption) as missing (Android's skippedSinceSeq).
- The Quick menu's Controllers item lists the pads (with battery) and Pair a controller; a PS5 stream over PSN
  changes its Away bitrate, with the Away steps; the PC bitrate list starts with Auto.
- The Auto bitrate base has no 150 Mbps cap any more (as Android).
- The TV controller screen keeps the iPad awake from the start, and the pad socket sends without Nagle delay.

Since that review, in the 1.0 beta 1 batch (pull requests #32 to #37): Xbox sign-in and stream robustness, PS5
robustness (retry counts, in-use wait, PSN to LAN switch, profile-based Away, weak-link 720p), frame pacing Balanced
with Android's style defaults, the PC menu (Resume, Test the network, Unpair, Remove unpairs) and the 15 s start
watchdog, All games parity (PlayStation and Xbox tabs, running-first sort, Offline badge, grid on iPad, Y toggles TV,
per-game Play on a TV), the Automatic bitrate row on style pages with Forget in Classic, and the PSN console ID
cleared on sign-out.

Not done yet, against the 2026-11-03 review (list 3a):

- DirectPad and the "Controller on a TV" setting (item 19).
- Pad as a mouse, a "Rumble on this device" toggle, a multi-pad test and per-pad rumble routing for PS5 (item 20).
- PS5 pacing and decoder-latency settings, and a Fastest style that uses them (item 14).
- Away key per network (one global "away" key remains) and the 64-entry cap on the link memory, to the extent the
  review's wording still applies (item 21); not re-checked line by line for this batch.
- PSN sign-in cookies: only the code comment and the DUID clearing are done; Android's bot-check cookie fix is
  not confirmed ported (item 22).
- PS4 support (item 23).
- A MoonCast receiver for Apple TV (item 25): the "Moonlight TV" target is still stock Moonlight tvOS.
- Siri Shortcuts (after beta 1, from the 2026-11-07 plan).

Not applicable on iOS: the "This device" tab and device apps, home-screen pinning, Exit, Obtainium, front buffer,
SSID/BSSID network keys, 144 and 240 fps, and picture in picture for Metal (PyroWave and Super resolution) streams.

Still to do before a public beta: a release build with the MoonCast bundle ID and the usage check-in ID built in,
and a way to distribute it (TestFlight needs a paid Apple Developer account).
