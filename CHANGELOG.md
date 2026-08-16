# CleanHUD Changelog

Versions are assigned on Nexus at upload time. Everything under **Unreleased**
ships with the next upload; paste that section into the Nexus changelog and
retitle it with whatever version number the upload gets.

## Unreleased

### 2001 Edition (this file only)
- Shipped defaults are pre-tuned for running alongside KeyBrute's "2001
  Shield HUD": ammo and grenades top-left, its shield/health meter carried
  to the top-right like real CE. Works out of the box with that mod's
  cluster_* offsets zeroed in its tuning.txt, so only one mod positions
  things. All positions still tunable with the hotkeys below.

### Fixed
- Hit markers now work while the crosshair is hidden with Shift+C. They live
  inside the reticle widget, so hiding the crosshair used to take them down
  with it; the crosshair pieces are now hidden individually instead. (c03c1f6)
- Ability/armor-mod icon no longer pushed off the right edge of the screen
  (reported by D00gs; was worst at higher HUD scales). It now has its own
  position, independent of the grenade counter. (c0bdb20)
- Removed the small pickup badge that flashed when collecting ammo or
  grenades. (c0bdb20)
- Removed a leftover debug logger that wrote ~2KB to UE4SS.log twice a second
  during play. (2f9eeef)
- Removed leftover developer tools from the build: F2/F3/F4 item-spawn keys
  and a grenade-cradle diagnostic logger.

### Changed
- New default HUD layout: the author's tuned classic-CE arrangement — ammo
  counter and grenades stacked in the top-left, ability icon beside them,
  matching the layout shared by that1dude0092 on Nexus. Existing users'
  settings.ini positions are untouched. (2f9eeef, 53862c2)
- Default HUD scale is now 0.75 (was 0.80). (53862c2)
- Shield bar starts at the game's own position; it only moves if you move it.
  (2fd7a26)
- The ammo and grenade position hotkeys moved from the arrow keys to
  Ctrl + Shift + WASD (ammo) and Ctrl + Alt + WASD (grenades). Arrow-key
  binds never fire while the 2001 Shield HUD's native module is loaded, so
  every position hotkey now lives on letter keys — which also work on 60%
  keyboards with no arrow row.

### Added
- Compatibility with KeyBrute's "2001 Shield HUD" mod: with both mods
  enabled, that mod owns the ARTWORK (its 2001 shield/health meter, its CE
  ammo styling) and CleanHUD owns the LAYOUT (positions, toggles,
  decluttering). CleanHUD stops hiding the widgets its meter is painted on,
  suppresses its own mirroring/scaling/ammo styling, which would mangle the
  painted textures, and keeps the meter on screen in crosshair-only mode.
  Position both mods' shared elements with CleanHUD's position hotkeys, and
  consider zeroing the cluster_* offsets in that mod's tuning.txt so only one
  mod positions things. Its "x" ammo separator is its own CE feature --
  toggle via ammo_ce_style in its tuning.txt.
- Ctrl + Shift + O — instantly toggle between the classic-CE layout (ammo
  top-left, the default) and the original arrangement (ammo top-right at the
  game's own position). Your choice is remembered across sessions, and your
  tuned CE positions are kept when switching back and forth.
- Ctrl + Alt + I/J/L/M — move the ability/armor-mod icon (I=up, J=left,
  L=right, M=down). (2f9eeef)
- Alt + Shift + I/J/L/M — move the shield/health bar (requested by
  that1dude0092). (2f9eeef)
- Ctrl + Shift + R — reset every HUD element to its shipped default position,
  live, and save. The rescue key if an element ever gets nudged off-screen.
- The classic-CE and original layouts each remember their own ammo-counter
  position, so tuning one arrangement no longer disturbs the other.
- Startup log line reports how many position hotkeys registered (16/16), so a
  broken binding is visible instead of silent. (33334ad)
