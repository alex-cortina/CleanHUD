# CleanHUD Changelog

Versions are assigned on Nexus at upload time. Everything under **Unreleased**
ships with the next upload; paste that section into the Nexus changelog and
retitle it with whatever version number the upload gets.

## Unreleased

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

### Changed
- New default HUD layout: the author's tuned classic-CE arrangement — ammo
  counter and grenades stacked in the top-left, ability icon beside them,
  matching the layout shared by that1dude0092 on Nexus. Existing users'
  settings.ini positions are untouched. (2f9eeef, 53862c2)
- Default HUD scale is now 0.75 (was 0.80). (53862c2)
- Shield bar starts at the game's own position; it only moves if you move it.
  (2fd7a26)

### Added
- Compatibility with KeyBrute's "2001 Shield HUD" mod: when it is installed
  and enabled, CleanHUD automatically hands it the shield meter, visor overlay
  and ammo readout instead of fighting it for them (CleanHUD's own OG-ammo
  styling turns off). Layout, decluttering and all toggles keep working.
  Known trade-off with both mods: no top visor wire in crosshair-only mode.
- Ctrl + Shift + O — instantly toggle between the classic-CE layout (ammo
  top-left, the default) and the original arrangement (ammo top-right at the
  game's own position). Your choice is remembered across sessions, and your
  tuned CE positions are kept when switching back and forth.
- Alt + Shift + Arrows — move the ability/armor-mod icon. (2f9eeef)
- Ctrl + Alt + Shift + Arrows — move the shield/health bar (requested by
  that1dude0092). (2f9eeef)
- Startup log line reports how many position hotkeys registered (16/16), so a
  broken binding is visible instead of silent. (33334ad)
