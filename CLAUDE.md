# CleanHUD — UE4SS Lua mod for Halo: Campaign Evolved

Strips the remake's HUD back to classic CE elements. One script: `Scripts/main.lua`.
Published on Nexus: https://www.nexusmods.com/halocampaignevolved/mods/100

## THE TRAPS (each of these cost hours — check them first)

1. **Two copies of this mod exist. The game runs the OTHER one.**
   - `C:\dev\CleanHUD\` = git repo / working copy. **THIS folder.**
   - `F:\SteamLibrary\steamapps\common\Halo Campaign Evolved\Meteorite\Binaries\Win64\ue4ss\Mods\CleanHUD\` = what the game loads.
   - Edit the game copy, then `cp` it here to commit. If a fix "does nothing," diff the two files before theorizing.
   - **RETIRED:** `C:\Users\User1\OneDrive\Desktop\CleanHUD\` was the old working
     copy. Do not edit or commit there — it is a stale clone of the same remote
     and editing it is a silent no-op, the exact failure this trap describes.

2. **The live settings.ini may not be where you think.**
   - Proper (current builds): `...\Win64\ue4ss\Mods\CleanHUD\settings.ini`
   - Legacy (pre-fix builds wrote to Lua's cwd = game exe dir): `...\Meteorite\Binaries\Win64\settings.ini`
   - Saved ini values SILENTLY OVERRIDE code defaults. If "constants don't apply," cat both files.

3. **Widget lookups lie three ways.** `FindAllOf` returns class-default objects
   (`Default__*`), stale instances from previous levels, and folder-name false
   matches (`/WeaponCradle/` also contains WBP_AmmoPickupBanner and
   WBP_WeaponCooldownBar). Single-target ops need: exact `_c` class suffix
   match + `is_shown()` + skip `Default__`.
   - Stale instances stay VALID and keep a walkable WidgetTree, so `IsValid()`
     and "has a tree" do NOT filter them — only `is_shown()` does. This has
     now caused three separate bugs (silent prune no-op, grid reparent onto a
     dead pair, decorations returning after a level change). Apply the full
     check to EVERY single-target lookup, not just the one being debugged.

## What works / what doesn't (UE4SS Lua, learned empirically)

- **Works:** RenderTranslation/RenderScale with flat `{X,Y}` tables; reparenting
  via `AddChildToGrid` / `AddChildToHorizontalBox`; mutating struct FIELDS of
  hook params in place; `SetBrushColor` (flat FLinearColor).
- **Crashes or dead ends (documented in main.lua comments — do not retry):**
  overriding params on hot hooks (SetVisibility/SetText); constructing
  FSlateColor; `GetCachedGeometry` (marshals empty); BP library CDO calls
  (go stale across levels); Pawn:GetBaseAimRotation (game never calls it —
  aim path is unreachable Blam C++, so crosshair position can't be changed).
- **HUD positioning:** never compute offsets from screenshots — tune live with
  the arrow-key hotkeys and bake the CE TUNE console values. The grenade box
  clips between x=375 (ok) and x=500 (vanish) at 16:9.

## Conventions

- Debug via `UE4SS.log` (flushes on game close) and `UE4SS_ObjectDump.txt`
  (~395k lines, full widget ownership paths) — both in the `ue4ss\` folder.
  Prefer the object dump over asking for in-game F-key dumps (they don't fire).
- Temporary diagnostics: one-shot deduped log lines, removed once the fix is
  confirmed. Never leave silent early-returns in new code paths.
- Lua scoping: a `local function` cannot call a `local` defined later in the
  file (silent nil at runtime). This has bitten twice; check declaration order.
- Perf: cache `FindAllOf` results in the 16ms loops; never add per-class scans
  to a fast loop (budget: <15 full-array scans/sec total).
- Commit when something is CONFIRMED working in game, not when it compiles.
- Versioning happens on Nexus at upload; no git tags or version bumps.
- Every user-visible change gets a bullet in CHANGELOG.md's Unreleased section
  in the same commit. At upload, the user pastes that section into Nexus and
  retitles it with the version the upload gets.
