# Changelog

All notable changes to Rune Mobile are recorded here, for both apps: one release
tag ships the Android APK and the iOS IPA together, and most fixes land in the
shared Java bridge both of them run. An entry that applies to one port says so.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
follow [Semantic Versioning](https://semver.org/).

The version is set once, in `android/app/build.gradle.kts`. Android's
`versionCode` is derived from it (`major*10000 + minor*100 + patch`) and is
strictly increasing so Android accepts update-in-place; the iOS build stamps the
same version into the IPA, and the AltStore feed shows this file's section for it
as "What's new".

## [Unreleased]

## [0.9.0] - 2026-11-07

### Added
- **The game has sound.** Music, sound effects and area sounds now play on both apps, and so do plugins that bring
  their own sounds. They mix with anything else you're playing, and they stop when you leave the app and come back
  when you return. Volumes are in the game's own settings, and Game settings > Sound > Game sound turns it all off.
  On iPhone the game also plays with the Ring/Silent switch on silent, so use Game sound to quiet it.
- **iPhone: the game eases off when the phone gets hot.** It lowers the frame rate as the phone warms up, on every
  renderer, and goes back up once it has cooled. Low Power Mode holds it to 30 fps.
- **iPhone: Share logs shows heat, battery, frame timing and memory readings,** a line a minute, to help with reports
  of a hot phone or of the app closing by itself. The memory readings survive the app being closed, so a report from
  the next launch still has them.

### Changed
- **iPhone: new installs start on GPU instead of 117 HD.** It runs much lighter on the phone, and 117 HD is still in
  the plugins panel. If you're already set up, nothing changes, and you can switch by hand.
- **iPhone: new installs start on lighter settings.** The frame rate is capped at 30 fps, with a shorter draw distance,
  and 117 HD starts with simpler shadows and lighting at a lower resolution. You can raise any of it in Game settings
  or the plugins panel. If you're already set up, your settings stay as they are.

### Fixed
- **Android: 117 HD no longer stays blurry after the app is closed on a hot phone.** The lowered resolution could
  stick and replace your own setting. A resolution scale you change while the phone is hot now sticks too. If yours
  is already stuck low, set it back once in the 117 HD settings.

## [0.8.0] - 2026-11-05

### Changed
- **Rebuilt on the latest RuneLite and game revision.** Updated to RuneLite 1.13.6 and the current OSRS revision, so
  the client keeps working after the recent weekly update instead of stopping at a black screen. The plugin catalogue
  is served for 1.13.6.
- **You log in yourself now.** The game stops at the login screen and waits for you to press Play Now, on the world
  you chose. It no longer signs in by itself or forces World 301, so the Default World plugin works, including
  "Use last world". Reconnecting after a dropped connection and hopping worlds are still automatic.
  If the game says you need a members' account, you're on a members world: tap Switch World and pick a free one.
- **Auto-login is a setting now.** Turn it on in Game settings and the game presses Play Now for you when it starts,
  on the Default World plugin's world. It's off by default, and logging out always leaves you at the login screen.
- **The orbs follow the game's Show data orbs setting.** With it off, the app used to draw the orbs anyway, and they
  looked alive but tapping them did nothing. They're hidden now, as they are on desktop, and a chat message at login
  says where to turn them on: All Settings, Interfaces. The world map button is one of the orbs, so it needs the
  setting too.

### Fixed
- **Double tap works in plugin panels.** Anything a plugin does on a double-click now happens on a double tap, as it
  does on desktop: double tap a row in Star Miners to hop to that world. When the game asks you to confirm the hop, the
  panel closes so you can see the question.
- **The RuneLite profile you pick stays picked.** It used to go back to the old one at every launch.
- **Choosing a world on the login screen picks the world you tapped.** It used to pick the row under your previous
  tap, which often ended in "You need a members' account to use this world".
- **iOS: the pinned keys no longer cover the login screen.** The camera arrows sat on top of the world switcher.
  Pinned keys and the hotkey strip stand aside until you're in the game.
- **Android: the world switcher on the login screen works.** The keyboard, Shift and Ctrl keys sat on top of it, so a
  tap turned on Shift instead of opening the world list. They stand aside until you're in the game, and so does the
  hotkey strip.

## [0.7.1] - 2026-11-01

0.7.0 was tagged but never released; its changes ship here, so this is the first release since 0.6.0.

### Added
- **Share logs, for bug reports.** One tap makes a text file to post with a report, and the phone's share sheet
  sends it to Discord, Messages or Files. It holds the app and device versions, the renderer, your plugins and
  their versions, recent log lines from the app and from RuneLite, and any crash report. Login tokens, emails
  and your character name are taken out before the file is made. Find it on the About screen; on iPhone also at
  the top right of the start screen, and on Android on the "game stopped" card.
- **A frozen game leaves a trail.** If the game stops moving for 20 seconds, RuneLite's log records what every
  thread was doing, and says so when the game's own thread has stopped, so Share logs can show what happened
  after you restart the app.
- **iOS: the Play screen says when StikDebug ran the wrong script,** before you tap Play. Right after the attach
  the app checks the script. If StikDebug attached without `runelite-jit.js` or ran a different one, Tap to Play
  stays off and the screen says which, instead of the app closing half a second after you tap it. The fix is the
  same either way: in StikDebug, long-press RuneMobile, Reset Script, then Assign Script and pick
  `runelite-jit.js`. Your current copy of the script keeps working; there is nothing to re-import. If the app
  still closes during start-up, the next launch says "The last start didn't finish" and how to fix it.

### Changed
- **Updated for the 1 November game update** (RuneLite 1.13.5, game revision 242). Plugin Hub plugins now come
  from RuneLite 1.13.5's list.
- **iOS:** the release IPA is built the same way as the rolling builds: ad-hoc sealed, with no developer
  provisioning profile inside. SideStore and AltStore re-sign it at install, as before.

### Fixed
- **NPC dialogues stay on screen.** A conversation showed for one frame and then vanished, though tapping still
  answered it ([#5](https://github.com/audaro/runemobile/issues/5)).
- **Dialogues fit the chat box.** Every page was cut off on the right: the speaker's head halved, and the end of a
  long line or option missing.
- **A dialogue's first and last frames draw the right chat box.** The first frame showed the text bare over the
  world, and the first frame after it closed kept the box behind the chat.

### Security
- The release pipeline's signing key and its permission to edit releases moved out of the build job, so the
  third-party tools a build runs can't reach them. The iOS runtime it downloads is checked against a pinned
  checksum.
- The headless login scripts in `ios/dev-tools/` no longer print the access token.

## [0.6.0] - 2026-10-28

### Added
- **Play with the phone held upright.** Settings > Game settings > Screen picks Landscape, Portrait or Auto, and
  the change applies at once. Portrait is the official mobile app's upright layout: the chat top left, the
  minimap top right, and the tab buttons bottom right with the side panel beside them. On a phone the world, the
  inventory and every window draw about a quarter bigger than the game's 765-pixel minimum layout would, while
  the chat and the minimap keep their usual size. A window opens in the space between the chat and the tab
  buttons, and the world map takes the whole screen.
- **Screen: Auto turns the game with the phone.** The game lays itself out again for the new shape mid-game and
  keeps a camera zoom for each way up. On iPhone, Auto reads the motion sensor, so it turns even with Portrait
  Orientation Lock on, and Landscape and Portrait act as the in-game lock. On Android it follows the phone's own
  auto-rotate setting.
- **The official mobile app's chat and tab buttons.** The tab buttons use the official app's icons, order and
  frame, and the arrow folds them to one column (kept across launches). Logout moves to a door left of the chat's
  filter row. Beside the chat sit the official speech bubbles, which put the chat away and flash while a message
  waits, and a keyboard button. A dialogue brings a put-away chat back while it lasts.
- **A developer guide** in [`docs/dev/`](docs/dev/README.md): setting up a machine, the architecture and threading
  model, the bridge API with a reference generated from the shared contract, each port, the three renderers,
  every test and gate, debugging by symptom, upstream merges and releases, and the traps that cost real time.

### Changed
- **Plugin boxes keep off the chat, the minimap and the buttons.** A plugin's box, such as Quest Helper's current
  step, an info box or a minigame panel, moves the shortest way to a clear spot when it would cover the chat and
  its buttons, the minimap, the tab buttons or the app's own on-screen controls. That includes a box moved in the
  overlay editor, which used to keep its saved spot over them.

### Fixed
- **The chat's typing line shows again.** The "name: *" line under the chat was cut off once the chat took the
  official app's smaller size.
- **Plugin Hub descriptions written in HTML show as plain text,** instead of raw markup such as `<html>`.
- **iOS: plugin settings section headers work with VoiceOver,** which reads each one as a button that is collapsed
  or expanded.
- **iOS: About shows the real version** in builds made outside the release pipeline, which used to say 0.1.

## [0.5.0] - 2026-10-26

### Added
- **iPad.** The iOS app runs on iPad, full screen and in landscape. The game's picture grows with the screen, so
  the chat, minimap and buttons keep the size they have on a phone and cover less of the view: the game draws at
  1390×913 on an iPad mini and 1689×1267 on a 13-inch iPad Pro. The plugin rail on the right edge keeps clear of
  the minimap and the tab buttons, and they move up to the edge when the rail is turned off. Checked in the iPad
  simulators only; speed on a real iPad isn't measured yet.
- **Foldables and Android tablets.** On a foldable's inner screen or a tablet, the game's picture grows with the
  screen and the chat, minimap and buttons stay at phone size, instead of a phone-sized picture being stretched to
  fill it. Folding or unfolding mid-game resizes the game to the new screen, and each screen keeps its own camera
  zoom. The game is never drawn narrower than its 765-pixel minimum layout, and a window of another shape gets
  black bars instead of a stretched picture. Tested on a Pixel 7a set to the screen sizes of a Galaxy Z Fold 7 and
  a 10-inch tablet, not yet on a real foldable. A bigger screen has more to draw, so the CPU renderer runs slower
  there than on a phone screen.

## [0.4.0] - 2026-10-26

### Added
- **Hold on the world map to open its menu.** A long press inside the open world map opens the same right-click
  menu the desktop map has, so plugins that add map options now work on the phone. With Shortest Path, hold a spot
  and choose Set Target, Set Start or Clear Path; hold a row of the map key for Find closest. Before, Android
  ignored a hold on the map, and on iOS the menu opened away from the finger. Dragging, pinching and searching the
  map work as before.
- **Game settings.** One screen in Settings for long-press time, camera sensitivity, idle logout, frame-rate cap and
  haptics. Idle logout and the frame-rate cap use RuneLite's Logout Timer and FPS Control plugins and turn them on
  when set. A cap above about 50 fps only takes effect with Unlock FPS on in the GPU or 117 HD settings.
- **A number pad for amounts.** Withdraw-X, Grand Exchange prices and quantities, and every other "Enter amount"
  open the phone's number pad, with a Paste button for a copied number.
- **Haptics for opening the menu and picking up an item,** next to the existing ones for menu rows and actions.
  Each of the four can be switched off on its own, and a strength setting makes them lighter or stronger.
- **Swipe to scroll the Grand Exchange item search.** A drag on the results scrolls them, and every result in view
  can be picked. Before, only the first 24 had a tap target, wherever they had scrolled to.
- **The screen stays awake in game.** The phone no longer dims and locks while you are logged in; on the login
  screen it locks as normal.

### Changed
- **Items need a short hold before they drag.** Rest a finger on an item for a moment, then drag. A quick flick
  across the inventory no longer moves an item or turns the camera, and in the bank, prayer book or spellbook a
  quick swipe scrolls the list when it has more than fits. The hold is two-thirds of the long-press time, at most
  150 ms.
- **Rebuilt on RuneLite 1.13.5-SNAPSHOT,** the line following Release 1.13.4. It brings RuneLite's reworked
  Party plugin and a fix for the Wiki DPS button. The Plugin Hub list moves up to the 1.13.4 release, so plugins
  updated for it install.

## [0.3.1] - 2026-10-23

### Fixed
- **Android 117 HD had no sun shadows** and looked flat and dark next to the iPhone at the same settings. 117 HD
  asks for its shadow map in a format the Android graphics driver refuses, so the map was never made and the
  whole scene was drawn as if in shadow. The app now asks for a format the driver accepts. Shadows cost frames:
  on a Pixel 7a, about 38 fps with Detailed shadows against 47 with them off. Shadows are in the 117 HD settings.
- **iOS: 117 HD's terrain shadows were missing** for the same reason. The fix for the main shadow map did not
  cover the terrain map, which uses a different format.

## [0.3.0] - 2026-10-23

### Changed
- 117 HD is updated on both phones from a June build to 1.6.0.1, the version the Plugin Hub serves. It brings
  four months of 117 HD's own work: see-through and double-sided models drawn properly, a seasonal foliage
  option, a ground-blending mode that blends only textures, reworked brick walls, new textures and lighting
  across many areas and quests, and lights on sailing boats. 1.6's day & night cycle stays off on both phones
  for now.
- 117 HD settings that 1.6 renamed keep your choice. 1.6 itself reads the old values as unset and goes back to
  its defaults, which on iOS turned tiled lighting back on for anyone who had switched it off.
- The app has a logo. On iOS it is the app icon (there was none before) and the launch screen, and it heads
  the tap-to-play cover and the About screen. On Android it is the launcher icon, the themed icon on Android 13
  and later, the notification icon and the TV banner, and it heads the splash and About screens.

### Fixed
- After a dropped connection the app logged back in but left you on the "Click here to play" screen until the
  game's idle logout. It now presses the button itself after a reconnect or a world hop. On Android it now
  does this on the first login too; before, you had to tap it.
- A dropped connection that lasted more than about 12 seconds ended on "Session expired" though your login
  was still good: the app's five quick tries to log back in all failed before the network was back. It now
  keeps trying for about two and a half minutes, at growing intervals, behind the "Reconnecting" screen.

### Internal
- `tools/shader-matrix/` checks every 117 HD shader the app builds, in 11 combinations of settings, against
  each phone's shading language with glslang, so a 117 HD update or a shader change is checked without a
  phone. See [its README](tools/shader-matrix/README.md).

## [0.2.7] - 2026-10-23

### Fixed
- Since 0.2.0, the 117 HD settings screen showed Entity Hider's settings (Hide others, Hide NPCs, …) instead
  of its own, and its "Reset all settings" reset Entity Hider. 117HD needs Entity Hider to load, and the app
  took the settings Entity Hider shares with it for 117HD's own. The screen shows 117HD's settings again:
  resolution, anti-aliasing, shadows, lights, normal mapping and draw distance.
- The Notes plugin had a settings screen with nothing on it but "Reset all settings", and one tap of that
  erased your notes. A plugin whose settings are all hidden no longer gets a settings screen; Notes keeps
  its switch and its side panel.
- The plugin side panels were drawn in Swing's default look instead of RuneLite's: a white border round
  every scroll pane, and text that ignored its font and colour (the Info panel's "Sign in" line came out in
  black serif). They now look as they do on desktop.

### Changed
- iOS: the XP Tracker screen reads the same once-a-second snapshot as Android's, built on the game's own
  thread, instead of reading the plugin's state from the screen's thread.

### Internal
- The iOS app runs in the iOS Simulator on a Mac, with the full JIT and no phone, and
  `ios/dev-tools/sim-gate.sh` checks each build there: every JNI lookup, the native screens against saved
  screenshots, every plugin's settings screen and side panel, a boot on each renderer, and the logs. The
  plugin sweep is what found the Notes screen above. It had passed the 117 HD screen, so it now also fails a
  settings screen that another plugin's row opens too. See
  [CONTRIBUTING.md](CONTRIBUTING.md#testing-in-the-ios-simulator).
- iOS, 117HD: every start logged shader compile errors for 117HD's calibration and debug overlays, which the
  app doesn't offer. Those shaders are now ported to the phone's shading language, as Android's already
  were, so 117HD starts with none. On both phones, the calibration dots no longer depend on behaviour the
  shading language leaves undefined.
- `tools/port-drift/` reports where the iOS and Android apps have drifted apart.

## [0.2.6] - 2026-10-22

### Fixed
- 0.2.5's tap change is withdrawn. A camera drag that paused before it moved walked your character, and a
  press-and-hold did the left-click action before its menu opened. The game acts on the press itself, and
  0.2.5 sent the press while your finger was still down, before anything could tell a tap from a drag. A tap
  now presses and releases together when you lift, as it did in 0.2.4. The same change had made an
  inventory drag let go of the item about a frame after picking it up.
- After a bank or Grand Exchange search, or an "Enter amount" prompt, the prompt's text stayed in the
  chatbox for the rest of the session.
- Android, GPU renderer: a translucent triangle could sit across part of the screen for seconds, and wall
  pieces dropped out for a frame while the camera turned.
- Android, GPU renderer: taking a screenshot (the Screenshot plugin takes one on a level-up) stopped the
  game, and reopening the app showed a black game area.
- iOS, GPU renderer: the login screens froze on their first frame, so a refused login and the game's
  "Try Again" were invisible behind a Play Now button that no longer did anything.
- An account saved in Resizable - Classic logged in with no usable side panel: on Android every tab opened
  into an invisible panel, and on iOS neither the tab stones nor the panel showed. Classic and Fixed now
  get the game's own HUD.
- A position saved in the overlay editor for the chat, the minimap or the side panel fought the app's own
  placement of them every frame. The editor no longer offers those, and clears positions already saved.
- iOS: an audio route change (AirPods connecting, a car stereo) stopped the background keepalive until the
  app next went to the background, so iOS could end a session that should have stayed alive. It now
  restarts at once.
- iOS: every launch left a 172 KB file behind in the app's caches. The ones already there are removed.

### Added
- A "Switch to Resizable - Modern" button at the top of the screen when your account is in Resizable -
  Classic or Fixed. One tap changes the setting the way the game's own Settings > Display does; the
  layout is saved to your account by the game, not by the app.
- The minimap can be moved in the overlay editor, with a "Minimap" handle like the "Chat" one. It keeps
  its place relative to the top-right corner, so a notch or a rotation still places it, and "Reset to
  default" puts it back. On Android, a chat or minimap drag the system cancelled now saves where it was
  left instead of jumping back on the next launch.
- iOS keeps a small record of how each session ended (durations, counters and a memory figure) to tell
  apart what ends a session in the background. It stays on the phone; see [PRIVACY.md](PRIVACY.md).

### Changed
- The GPU renderer's vsync starts on. On Android, frames follow the display instead of a 60 fps sleep
  that drifted against it; iOS keeps its frame limiter, because its presents take no swap interval. A
  change in the plugin panel survives relaunch.
- Android, CPU renderer: frames are presented on the display's refresh instead of after a fixed 16 ms
  sleep, which ran under 60 Hz on a 90 Hz screen.
- Less work per frame: the relocated HUD is re-laid only when it moves, snapshots are republished only
  when they change, and on iOS the frame copy for the screen runs off the main thread.

## [0.2.5] - 2026-10-20

### Fixed
- The client could not log in after the 20 October game update. Jagex changes the game's content and its
  revision most weeks, and a client built against the previous one is turned away at the door with
  `js5connect_outofdate` — in practice a black screen with no useful explanation. This build is rebuilt
  against RuneLite 1.13.4-SNAPSHOT — the line following Release 1.13.3 — and the 20 October game data,
  so login works again. This will happen again after future weekly updates until a new build is
  published; it is the commonest reason to check the releases page.
- Opening the world map left the minimap orbs, the compass and the "Walk here" text painted on top of it.
  A map that takes the whole screen now owns all of it: the layers that would paint over it are held down
  while it is open and handed back exactly as they were found, so a panel the game itself had closed is
  not forced back on.
- The "Walk here" label appeared with nothing touching the screen — while rotating the camera, and after
  a tap had already finished. The client was still tracking a pointer where your finger used to be, and
  the game re-read that point every tick as the world turned underneath it.
- A tap was reported to the game as a one-millisecond hold no matter how long you actually held it, and
  the few pixels of roll a finger makes between landing and lifting were discarded. The press now goes out
  while your finger is still down and closes where it actually left the glass, so the hold the game sees
  is the hold you made. The hold itself is shared code both ports run from the same jar; the
  finger-travel half is separate Android-only plumbing that has not yet been exercised on an Android
  phone, where it falls back to a single position at contact if it does not take.
- A tap that failed mid-flight could leave the left button down, and a held button walks your character.
  The press is now retired first, so it cannot outlive the tap that opened it.
- A press-and-hold that rolled a few pixels was discarded instead of opening the menu.

### Changed
- Hover text is off. A touchscreen has no hover: nothing rests over anything, so a label naming what is
  underneath describes a cursor that does not exist. The official mobile app shows none either. Launch
  with `-Drunelite.hover.text=true` for the desktop behaviour.
- Typed text takes real time to arrive. A thirty-character paste used to land complete inside a single
  game tick, which no keyboard has ever done; it now types out over about a second.

### Removed
- **The idle keepalive — this changes when you are logged out.** The app used to post a synthetic mouse
  event every couple of seconds while you were in its own menus, so the game's idle timer never climbed
  and you were never logged out while sitting in them. That event came from nobody. It is gone end to
  end, and you will now be logged out after the usual idle period exactly as desktop RuneLite does.

## [0.2.4] - 2026-10-18
### Fixed
- Some dialogue boxes still could not be answered, even after 0.2.3 taught the client to recognise
  them. The tap stopped falling through to the world — which is what made it look fixed — but nothing
  was pressed either. The client decides which boxes it can answer itself and which the game must
  answer, and the two lists had drifted apart: quantity boxes ("how many do you wish to make?") and
  the item-reward boxes were on the first list without ever being answerable from it, so a tap on them
  was refused by both paths. Having a name for a box no longer implies the client can drive it, so
  those are now answered by pressing the button under your finger, like every other box the game draws
  for itself. The space bar and the number keys could not answer them either, for the same reason.
- Searching for an item in the Grand Exchange or a bank was unusable. The search box and its results
  are drawn in the chat area, which the mobile layout moves and covers: the prompt was hidden outright
  while the Grand Exchange window was open, and once shown, the results were drawn over bare scenery
  with no backing, leaving item names floating over the world. The search now owns the chat area while
  it is open, is drawn on its own opaque background, and a result is picked by the row you tap rather
  than by a click the window swallows.
- Taps on the game world felt sluggish and sometimes did not register. A tap was only resolved once
  the finger left the glass, and a few pixels of ordinary finger roll was enough for the client to
  decide a tap had been a drag and discard it. The tap is now resolved while the finger is still down
  and committed to where it landed rather than where it lifted, so it survives a roll; the marker ring
  is drawn the moment the finger lifts rather than when the game answers, and takes its colour once
  the answer arrives. On Android the same roll also cancelled the press-and-hold, so a sloppy hold
  never opened the menu; it does now.

### Changed
- The marker ring is drawn for every world tap as it lifts, in the walk colour, and recoloured or
  withdrawn when the game says what the tap hit. Previously no ring appeared until the game answered,
  which for a plain walk — the commonest tap there is — meant a marker arriving a quarter-second after
  the finger had gone, or not at all.

## [0.2.3] - 2026-10-16
### Fixed
- Dialogue boxes the game opens for itself could not be answered at all. Quest confirmations, "are you
  sure you want to destroy this", crate and reward boxes — anything the game puts in the chat area that
  isn't one of the handful of dialogue layouts the client knows by name — were not treated as dialogues,
  so the native chat veneer stayed on top of the box and a tap on Yes or No either went to the chat or
  resolved against the scene behind it, walking the character away and ending the conversation. Any box
  the game opens in the chat area is now recognised as a dialogue, covered, and answered by pressing the
  button under your finger rather than clicking through it.
- Tapping near the top of a dialogue switched a chat channel instead of answering it (Android). The
  native chat tab row is drawn across the top of the chat area, which is exactly where the dialogue
  appears, and it took the tap before the box underneath could see it. The row now steps aside for as
  long as a dialogue is open, as it already did on iOS.
- A tap meant for one dialogue could answer the next one. A tap waiting on the game thread survived a
  loading screen or a world hop, so it could land on whichever box happened to be open when the game
  came back. A waiting tap is now stamped with the frame it was made on, and dropped if it hasn't been
  applied by the next one.

### Added
- The app now says at launch that it is built for the Resizable - Modern layout, with a "don't show
  again" for anyone who has already set it. The touch controls, chat and overlays are laid out against
  that layout and no other, which was true but written down nowhere.

## [0.2.2] - 2026-10-15
### Fixed
- The renderer could ignore the setting entirely. Marker files used by development and test runs were
  read by every build, so an empty leftover file outranked the saved preference: the panel showed CPU
  selected while every launch ran 117HD, with nothing on screen able to explain it. Release builds now
  decide the renderer from the preference alone, and those files are honoured only in development
  builds. The same files could also skip the sign-in step that normally comes first.

### Changed
- The game's boot thread no longer wakes four times a second for the whole session. It was polling
  counters that only move when frame capture is on — a development-only mode — and printing a line a
  second that a release build discards. It now sleeps quietly unless there is something to record,
  which saves battery and avoids pointless disk writes during a long session.

## [0.2.1] - 2026-10-15
### Fixed
- Tapping a dialogue walked the character instead of answering it. When the engine draws its own
  dialogue the native parchment is suppressed, so the touch never reached the overlay and fell back
  to a positional click, which resolved against the scene behind the dialogue box — moving the player
  to the tile under the text and ending the conversation by walking away. Dialogue taps now drive the
  engine's own continue and option handlers, so a tap advances the conversation or selects the row it
  landed on. Option rows that miss every row are consumed rather than answered with a blind advance;
  make-X and reward boxes, which the client does not model, keep their direct click.
- Answering a dialogue no longer counts as being idle. The positional click it replaced was input the
  game's idle timer could see, so a long conversation could trigger an AFK logout mid-sentence.
- The renderer tiles showed the saved preference rather than what the next launch would actually run.
  A device marker or a TV default outranks the preference at boot, so the panel could show CPU
  selected while 117HD ran. The tiles now reflect the next launch, and say so when a pick is being
  overridden.

### Internal
- The build now fails if the staged client jar is missing the dialogue handlers. The app resolves them
  optionally so an older jar still boots, which meant a stale jar produced dialogue taps that silently
  did nothing at all.

## [0.2.0] - 2026-10-13
### Fixed
- 117HD could not load at all and so never appeared in the plugin panel. Upstream began requiring a
  `@PluginDependency` target to expose its services; `EntityHiderPlugin` never did, so instantiating
  `rs117.hd.HdPlugin` failed outright. Entity Hider now shares itself and its config with dependents
  (`rs117.hd.scene.LightManager` injects both), so the renderer loads and the panel row appears.
- RuneLite-account login failed with a JSON parse error. The API base was pinned to a retired
  `api.runelite.net` version; it tracks the build version again, which also restores Grand Exchange
  price lookups.
- A failed API call now reports its status code and URL instead of surfacing as
  "Expected BEGIN_OBJECT but was STRING", which named neither.

### Changed
- Rebased onto upstream RuneLite `1.13.2-SNAPSHOT` (tag `runelite-parent-1.13.1`), bringing
  `rev241` (2026-10-07) game data: new GameVals/Legacy ID classes, item variations, and the
  Sailing skill-calculator data.
- Grand Exchange offer price/spent widened `int` -> `long` upstream; the native GE panel now
  parses the wider values (`optLong`), so a total past `Int.MAX_VALUE` no longer truncates.
- Upstream removed its Grand Exchange crowdsourcing upload outright, so the mobile privacy gate
  that suppressed it is gone as redundant. No GE offer data leaves the device, as before.
- The in-app Discord button and the embedded client's invite pointed at RuneLite's server. They now
  point at this project's own Discord: RuneLite does not support this unofficial fork, so anyone who
  followed the old link was turned away.

## [0.1.0]
Initial pre-release of the native Android client: real RuneLite headless on an
embedded arm64 OpenJDK 21, CPU/base-GPU/117HD renderers (caps-probed), Jagex
OAuth + RuneLite-account sync, native HUD/chat/tab-grid veneers, plugin panel.

### Notes
- Unofficial, sideload-only — not affiliated with or endorsed by Jagex/RuneLite;
  use at your own risk including account ban. See README.
- Release signing: a dedicated key via `keystore.properties` when present, else
  the debug key (see `keystore.properties.example`).

[Unreleased]: https://github.com/audaro/runemobile/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/audaro/runemobile/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/audaro/runemobile/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/audaro/runemobile/compare/v0.6.0...v0.7.1
[0.6.0]: https://github.com/audaro/runemobile/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/audaro/runemobile/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/audaro/runemobile/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/audaro/runemobile/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/audaro/runemobile/compare/v0.2.7...v0.3.0
[0.2.7]: https://github.com/audaro/runemobile/compare/v0.2.6...v0.2.7
[0.2.0]: https://github.com/audaro/runemobile/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/audaro/runemobile/releases/tag/v0.1.0
