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

Not done yet: the rest of the review's list 3a (Balanced frame pacing, Xbox and PS5 robustness items, Unpair, the
Automatic bitrate row on style pages, DirectPad, PS4 and others).
