# MoonCast for iPad: parity with the Android handheld

What the handheld app (MoonCastDev/moonlight-android, `app/src/handheld`) does, and where each piece stands here.

| Area | Handheld feature | iPad |
|---|---|---|
| Home | Row of big tiles: running, last played, consoles, then PC games A to Z | Done |
| Home | Box art, PC/PS5/Xbox badge, Running pill, colour wash, name line | Done |
| Home | Entrance animation, breathing cyan ring, hint bar with a pad | Done |
| Home | Round buttons: Consoles, Play on TV, Controllers, Network test, Settings, Exit | Consoles, Controllers, Network test, Settings (Play on TV to do; Exit: iPadOS has none) |
| Home | Add apps tile / This device's apps | Not possible on iPadOS (no launching other apps) |
| Games | All games grid, tabs per source (L/R), A to Z or Recent (X) | Done (PC tabs) |
| Games | Game menu: Start/Resume, Quit, Change picture, Hide, Add to home screen | Done except Add to home screen (iPadOS can't pin; Siri Shortcuts later) |
| Consoles | PCs: pair with PIN, wake, quit, hidden games, remove, add by address, away address | Done |
| Consoles | PS5: register, PSN sign-in, wake, play at home and away | Play at home, wake, PSN sign-in, linking with the 8-digit code and live status built (untested); away to do |
| Consoles | Xbox: sign-in, consoles list, play | To do (WebRTC + xCloud/xHome protocol) |
| Stream | Moonlight PC stream | Done (Moonlight's own) |
| Stream | Quick menu: stats, Keyboard, Streaming status, Touch Off/Mouse/Touch, Controllers, Task Manager, Disconnect, Quit | Done, tested on a stream (2420x1668 60 fps H.265) |
| Stream | Hibernate PC | Hidden (as in the Android release) |
| Stream | FSR 1.0 super resolution | To do (Metal port) |
| Settings | Picture: resolution (Native default), fps, bitrate, codec, HDR, frame pacing, stats | Done |
| Settings | Sound, Controls (touch default, on-screen pad, players, swap, mouse), Theme, About | Done |
| Settings | Screen size, rotate, menu sounds, controller test, deadzone, motion | Done except deadzone and motion (Moonlight iOS has neither yet) |
| TV | Play on a MoonCast TV, handheld as the TV's controller | To do |
| Other | Opt-in usage check-in (TelemetryDeck) | To do |
| Other | Obtainium updates | Not possible on iPadOS (TestFlight instead) |
