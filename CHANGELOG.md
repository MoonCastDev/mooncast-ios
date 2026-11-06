# Changelog

## 1.0 beta 1

The first MoonCast beta for iPhone and iPad. Not published yet: build it from source (see the README).

### Home
- One tile per PC; pressing it opens that PC's games. Consoles, "playing on" chip, empty-home help and a Pair tile for each unpaired PC.
- All games: All, PC, PlayStation and Xbox tabs, the running game first, an Offline badge on PCs that don't answer, a grid on iPad, and Y (pad) to choose between playing here and on the last TV.
- Upright: the home turns with the device; games still play on their side.
- Themes: Light, Dark, OLED, and Background that follows the game or stays static.
- Version shows as MoonCast 1.0.

### Settings and play styles
- Settings as cards, with the Classic list still available.
- Play styles for PC (Battery, Balanced, Sharpest, Fastest, PyroWave) and for PS5 and Xbox, each with its own page, icon and colour.
- Home and Away profiles and three custom profiles you name.
- Frame pacing: Lowest delay, Balanced, Smoothest. The PC styles use the same pacing defaults as Android.

### PC, PS5 and Xbox streaming
- PC menu: Resume, Test the network, Unpair; Remove unpairs first.
- Start watchdog: a stream that has not started in 15 seconds is retried once, then ends with a plain message.
- PS5: 20 tries on the home network and 4 over PlayStation Network, "Remote Play in use" wait (up to 30 s), switch from PlayStation Network to the home network when the console answers, Home/Away settings follow the profile, Away starts at 60 fps HEVC, bitrate up to 100 Mbps, 720p on a weak link.
- Xbox: console list refreshed when the home opens, a 60-second no-picture watchdog, only "not ready" failures are retried, automatic resolution (720p on a weak link, 1081 on tall screens, else 1080), a fresh account choice at each sign-in.
- PlayStation sign-out clears the console ID.
- Picture in picture for PC and PS5 games, in release builds too.
- Wake: the app watches the PC until it answers.
- Move to TV waits for the PC to let go.

### Quick menu
- Actions keep the menu open.
- Bitrate changes while playing (with Auto for PC); Play on TV with a choice of TV; Controllers with battery level and Pair a controller.
- Streaming status: Off, Lite, Detailed. The card stays under the menu.

### PyroWave
- PyroWave decoding on Apple GPUs through a Metal port.
- Picture settings for PlayStation and Xbox of their own.

### Automatic bitrate
- Off by default. Follows the design in docs/auto-bitrate-design.md of the Android repository, with a limit remembered per network and a per-place memory for away streams.
- Automatic bitrate row on every play-style page; Forget the limit in Classic.
- moonlight-common-c no longer counts packets it dropped itself as missing.

### Fixes in this batch
- Xbox sign-in and stream robustness (Android parity).
- PS5 robustness (Android's retry counts, in-use wait, PSN to LAN switch).
- Frame pacing Balanced and the PC menu with the start watchdog.
- All games parity with Android.
- Automatic bitrate row on style pages, and the PSN console ID cleared on sign-out.
