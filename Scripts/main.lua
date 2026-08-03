--=====================================================================
--  CleanHUD  -  a UE4SS Lua mod for Halo: Campaign Evolved
--
--  Strips the modern HUD back to the o.g CE-relevant elements (shields, radar,
--  ammo, grenades, equipment, crosshair), digs into WBP_HUD_Main to hide
--  baked-in decorations (visor frame, wires, cradle brackets, pickup box,
--  button-prompt glyphs), nudges the grenade/weapon counters into the
--  corners, and gives an OG-style ammo readout (mag + "/"
--  hidden, reserve kept and brightened).
--
--  Hotkeys:
--    Ctrl+Shift+H  - crosshair-only mode (hide everything but the reticle)
--    Ctrl+Shift+V  - toggle the Halo-3-style visor lines on/off
--    Ctrl+Shift+N  - toggle objectives + waypoints + pickup markers
--    Shift+N       - toggle just the waypoints / nav markers
--    Shift+C       - toggle the crosshair on/off
--    Ctrl+Shift+Arrows - CE layout: nudge the ammo cradle (saved to settings.ini)
--    Ctrl+Alt+Arrows   - CE layout: nudge the grenade/equipment group (saved)
--    F9            - full dump of every live UI widget (top-level)
--    F7            - keeper layout report
--    F6            - tree dump: WBP_HUD_Main's internal children by name
--    F8            - ammo/text widget dump (name | text | vis | tag)
--=====================================================================

local HIDE_ON_STARTUP = true
local ENFORCE_INTERVAL_MS = 1000
local HUD_PATH = "/game/ui/hud/"

local function log(msg) print("[CleanUI] " .. tostring(msg) .. "\n") end

--------------------------------------------------------------------
--  SETTINGS PERSISTENCE  (read/write settings.ini next to the mod)
--------------------------------------------------------------------

-- Lua's io paths resolve against the PROCESS working directory, which is the
-- game exe folder (Win64), NOT the mod folder -- debug.getinfo gives no usable
-- path in UE4SS, so earlier builds silently wrote "settings.ini" next to the
-- game exe. That shadow file kept overriding shipped defaults for hours before
-- anyone found it. Proper location is the mod folder, reached relative to the
-- exe dir; the legacy exe-dir file is still read (then superseded) so existing
-- users' settings migrate instead of resetting.
local SETTINGS_FILE   = "ue4ss/Mods/CleanHUD/settings.ini"
local LEGACY_SETTINGS = "settings.ini"   -- pre-fix builds wrote here (exe dir)

local function read_ini_into(path, t)
    local f = io.open(path, "r")
    if not f then return false end
    for line in f:lines() do
        if not line:match("^%s*#") then
            local k, v = line:match("^([%w_]+)%s*=%s*(.+)$")
            if k then t[k] = v:match("^%s*(.-)%s*$") end
        end
    end
    f:close()
    return true
end

local function read_settings()
    local t = {}
    read_ini_into(LEGACY_SETTINGS, t)   -- migrate old location if present...
    read_ini_into(SETTINGS_FILE, t)     -- ...proper location wins on conflict
    return t
end

local function write_settings(tbl)
    local f = io.open(SETTINGS_FILE, "w")
    if not f then
        -- unexpected cwd (non-standard launcher): keep persistence alive by
        -- falling back to the legacy exe-dir location rather than losing saves
        f = io.open(LEGACY_SETTINGS, "w")
        if f then SETTINGS_FILE = LEGACY_SETTINGS end
    end
    if not f then log("settings: could not write " .. SETTINGS_FILE); return end
    f:write("# Clean HUD - settings\n")
    f:write("# Edit to set your launch defaults, or change them live in-game.\n")
    f:write("# Toggles are true/false; hud_scale is a number like 0.80.\n")
    local order = { "visor_lines", "hud_scale", "hide_crosshair", "crosshair_only",
                    "show_objectives", "show_navpoints", "ce_layout",
                    "ce_ammo_x", "ce_ammo_y", "ce_gren_x", "ce_gren_y" }
    for _, k in ipairs(order) do
        if tbl[k] ~= nil then f:write(k .. "=" .. tostring(tbl[k]) .. "\n") end
    end
    f:close()
end

-- save_current() is defined after all state variables (see below INTERNALS)

local function bool_val(s, default)
    if s == nil then return default end
    return s:lower() == "true"
end

local ini = read_settings()
if next(ini) then
    log("settings: loaded from " .. SETTINGS_FILE)
else
    log("settings: no saved settings found, using defaults (will save on first toggle)")
end

local KEEP_VISOR_LINES = bool_val(ini.visor_lines, false)
local NEVER_TOUCH = { "wbp_hud_main" }

-- HANDS OFF: elements the mod must never show OR hide, in any mode, so the
-- GAME's own settings control them. Hit markers live under /Game/UI/Hud/ and
-- so were being collapsed every pass just for not being on the keep list --
-- which also stomped the game's built-in "disable hit markers" option
-- whenever it tried to show them. Unlike KEEP (skipped by apply, but still
-- force-shown by restore_all and hidden in crosshair-only), this list is
-- checked FIRST everywhere and means genuinely untouched.
local LEAVE_TO_GAME = { "hitmarker" }
local KEEP = {
    "shieldhealthbar", "motiontracker", "weaponcradle",
    "grenadecradle", "reticle", "interactprompt",
    "equipmenticon",   -- the equipment/ability selector
    "banner",          -- checkpoint / notification banners
    "countdown",       -- mission announcements, hazard countdowns, banner text
    "chaptertext",     -- chapter-title card + letterbox bars
}

-- Targets are which hud elements the scaling applies to, 
-- deliberately not the crosshair or chapter cards.
local SCALE_TARGETS = {                                    
    "shieldhealthbar", "motiontracker", "weaponcradle",
    "grenadecradle", "equipmenticon",
}

-- Default HUD size on startup = 0.80x. remake HUD is ~20% 
-- chunkier than classic CE according to AI calculations 
-- when comparing screenshots.
local HUD_SCALE      = tonumber(ini.hud_scale) or 0.80
local HUD_SCALE_MIN  = 0.50 
local HUD_SCALE_MAX  = 1.50 
local HUD_SCALE_STEP = 0.05

-- Scale PIVOT per element (normalized 0-1 within the element).
-- Scaling around the element's screen-facing corner keeps it 
-- hugged to that edge instead of drifting inward. 
-- Default center (0.5,0.5) is used for anything not listed here.
local SCALE_PIVOT = {
    shieldhealthbar = { x = 0.5, y = 0.0 },  -- top-centre
    weaponcradle    = { x = 1.0, y = 0.0 },  -- top-right (ammo / weapon icons)
    grenadecradle   = { x = 0.0, y = 0.0 },  -- top-left
    equipmenticon   = { x = 0.0, y = 0.0 },  -- top-left
    motiontracker   = { x = 0.0, y = 1.0 },  -- bottom-left (radar)
}

-- "Crosshair-only" mode: when toggled on (see KEY_CROSSHAIR below), 
-- EVERYTHING is hidden except the crosshair.
local CROSSHAIR_ONLY_KEEP = {
    "firstpersonreticle",  
}

-- Extra top level HUD elements to hide by name.
local EXTRA_HIDE = {
    "hudwidgetbacker",  -- the opaque black backing boxes (always hidden - ugly)
    "wbp_metu_divider", -- divider lines (always hidden)
}

-- Internal pieces (inside WBP_HUD_Main / keepers) to hide by name. Substrings,
-- case-insensitive, matched against each internal widget's instance name AND
-- its class. Add names from the F6 tree dump to strip more baked-in flourishes.
-- (OG-CE ammo styling is handled separately by apply_og_ammo + the reserve HIJACK hook; see the OG AMMO section below.)
local CHILD_HIDE = {
    "cradleframe",       -- the vertical bracket accents flanking the cradles
    "frame_image",       -- the ugly border box behind the pickup/interact prompt
}

-- The "visor line" decorations. Hidden while KEEP_VISOR_LINES is false, shown when true.
-- Toggled live with Ctrl+Shift+V. 
-- VISOR_EXTRA = top-level widgets
-- VISOR_CHILD = pieces nested inside the HUD
-- Only the actual "lines" come back with the visor toggle: the screen-edge
-- frame plus the wires/sweeps. The black backer boxes stay hidden (see EXTRA_HIDE).
local VISOR_EXTRA = { "frameborder" }
local VISOR_CHILD = { "bottomwires", "artifactshud", "visoroverlayimage" }

-- The persistent HUD button-prompt glyphs (equipment "G", etc.) are
-- WBP_MetUI_ActionWidget - the SAME class as the world pickup/interact glyph,
-- so we can't match by name alone. Instead we hide an action-widget ONLY when
-- one of these owners is somewhere in its ownership chain. That kills the
-- cradle badges while leaving the pickup/interact and menu prompts intact.
local HIDE_ACTIONWIDGET_UNDER = {
    "equipmenticon", "grenadecradle", "vehicleboost", "weaponcradle",
}

-- MOVE HUD elements to a corner/edge. Works on elements in an "OverlaySlot"
-- (the shield bar, reticle, interact prompt). Each entry maps a widget-name
-- substring to an alignment:
--   h (horizontal): 0=Fill  1=Left   2=Center 3=Right
--   v (vertical):   0=Fill  1=Top    2=Center 3=Bottom
-- So {h=1, v=1} = top-left corner, {h=3, v=3} = bottom-right, etc.
local MOVE = {
    -- (shield bar left at its normal top-center position)
}

-- NUDGE elements by a pixel offset (works on ANY element, any container type).
-- X: negative = left, positive = right.  Y: negative = up, positive = down.
-- Tune these numbers to taste; they re-apply every second so they stick.
local TRANSLATE = {
    ["grenadecradle"] = { x = -70, y = 45 },  -- push grenade toward bottom-LEFT
    ["equipmenticon"] = { x = -70, y = 45 },  -- keep equipment with the grenade
    ["weaponcradle"]  = { x = 70,  y = 45 },  -- push weapon toward bottom-RIGHT
}

-- CE LAYOUT: arrange the cradles like original Halo CE (confirmed against a
-- real CE screenshot): ammo counter in the TOP-LEFT corner with the grenade
-- count sitting just to its right -- NOT in opposite corners (that's Halo 2/3).
-- Because the cradles sit in different container types (GridSlot vs
-- HorizontalBoxSlot), slot alignment can't cross the screen -- so this is done
-- with RenderTranslation in design-space units (~1920 wide regardless of
-- actual resolution). Tune the constants by eye.
-- NOTE: on ultrawide (21:9) the weapon-cradle constant will land short.
-- Persisted as ce_layout in settings.ini.
local CE_LAYOUT      = bool_val(ini.ce_layout, true)
-- Offsets are PER-USER: the effective distance depends on the player's in-game
-- HUD scale and aspect ratio, so there is no single correct constant. (The
-- "correct by default" alternatives were tried and are dead ends in UE4SS:
-- Slate geometry reads marshal as empty structs, and reparenting into
-- GrenadeAndEquipmentGridPanel succeeded structurally -- slot calls all
-- returned true -- but the panel's own column layout still stretched the cell
-- full-width and the cradle re-attached to the right edge.) So: sensible 16:9
-- defaults below, live tuning via Ctrl+Shift/Ctrl+Alt + Arrows, and the tuned
-- values persist per-user in settings.ini.
-- Defaults computed from 16:9 screenshot measurements (~0.44 px/unit at this
-- setup): target is the far top-LEFT corner (grenades move to the right-side
-- box, vacating it). -3525 would land the corner from the measured -2900
-- position; the grenades joining the cradle's HorizontalBox shifts its layout
-- left by roughly their width, so the net constant is smaller. Fine-tune with
-- the arrows; values persist per-user.
-- Edge-hugging defaults, computed from a verified measurement pair (ini value
-- + rendered screenshot, 0.54 px/unit at 16:9) to match the radar's ~65px
-- corner margin. Earlier defaults were flying blind against a shadow ini that
-- overrode them -- see the settings-path note above.
local CE_AMMO_X      = tonumber(ini.ce_ammo_x) or -3010
local CE_AMMO_Y      = tonumber(ini.ce_ammo_y) or -10
-- Grenade offsets are applied AFTER the reparent into the right-side box
-- (see CE GRENADES RIGHT): a nudge from the box's layout spot to the screen
-- edge. Before the reparent they stay at 0,0 -- translating them while still
-- inside their grid cell is what used to make them vanish (cell clipping).
-- 375/0 was found by LIVE tap-tuning on screen, not computed: the right-side
-- box clips somewhere between x=375 (visible, packed to the corner) and x=500
-- (gone). Values beyond that vanish the grenades on the reference setup.
local CE_GREN_X      = tonumber(ini.ce_gren_x) or 375
local CE_GREN_Y      = tonumber(ini.ce_gren_y) or 0

if CE_LAYOUT then
    TRANSLATE["weaponcradle"] = { x = CE_AMMO_X, y = CE_AMMO_Y }
    -- The cradle is MIRRORED in CE layout (negative X scale in apply_hud_scale).
    -- Pivot on the RIGHT edge (x=1.0), and specifically NOT the centre: the
    -- cradle is right-anchored and grows LEFTWARD as its content widens (the
    -- AR's 32-pip row vs the shotgun's short one), so any pivot that depends on
    -- width makes each weapon land at a different X. The right edge is the one
    -- point the layout holds fixed -- reflecting across it makes the rendered
    -- LEFT edge width-independent, so every weapon lines up at the same spot.
    SCALE_PIVOT.weaponcradle  = { x = 1.0, y = 0.0 }
    -- Grenades: ZERO until the reparent lands them in the right-side box --
    -- translating them inside their original grid cell just clips them out of
    -- view. ce_grenades_right() applies the CE_GREN offsets on the move event.
    TRANSLATE["grenadecradle"] = { x = 0, y = 0 }
    TRANSLATE["equipmenticon"] = { x = 0, y = 0 }
end

-- (no master on/off key -- the mod stays on; disable the mod file to see vanilla)
-- Crosshair-only mode uses a modifier combo so NOTHING else can collide with it.
local KEY_CROSSHAIR      = Key.H
local KEY_CROSSHAIR_MODS = { ModifierKey.CONTROL, ModifierKey.SHIFT }  -- Ctrl+Shift+H
local KEY_VISOR          = Key.V
local KEY_VISOR_MODS     = { ModifierKey.CONTROL, ModifierKey.SHIFT }  -- Ctrl+Shift+V
local KEY_DUMP      = Key.F9
local KEY_REPORT    = Key.F7
local KEY_TREE      = Key.F6
local KEY_AMMODUMP  = Key.F8   -- diagnostic: list ammo/number widget names
local VIS_COLLAPSED = 1
local VIS_VISIBLE   = 0

--------------------------------------------------------------------
--  INTERNALS
--------------------------------------------------------------------

local enabled = HIDE_ON_STARTUP
local crosshair_only = bool_val(ini.crosshair_only, false)
local hide_crosshair = bool_val(ini.hide_crosshair, false)
local reported = {}

local show_objectives = bool_val(ini.show_objectives, false)
local show_navpoints  = bool_val(ini.show_navpoints, true)

local function save_current()
    local ok, err = pcall(write_settings, {
        visor_lines    = tostring(KEEP_VISOR_LINES),
        hud_scale      = string.format("%.2f", HUD_SCALE),
        hide_crosshair = tostring(hide_crosshair),
        crosshair_only = tostring(crosshair_only),
        show_objectives = tostring(show_objectives),
        show_navpoints  = tostring(show_navpoints),
        ce_layout       = tostring(CE_LAYOUT),
        -- tuned cradle offsets (only meaningful -- and only written -- in CE
        -- layout; reads the live TRANSLATE tables so hotkey nudges are captured)
        ce_ammo_x = CE_LAYOUT and TRANSLATE["weaponcradle"]
                    and string.format("%d", TRANSLATE["weaponcradle"].x) or nil,
        ce_ammo_y = CE_LAYOUT and TRANSLATE["weaponcradle"]
                    and string.format("%d", TRANSLATE["weaponcradle"].y) or nil,
        ce_gren_x = CE_LAYOUT and TRANSLATE["grenadecradle"]
                    and string.format("%d", TRANSLATE["grenadecradle"].x) or nil,
        ce_gren_y = CE_LAYOUT and TRANSLATE["grenadecradle"]
                    and string.format("%d", TRANSLATE["grenadecradle"].y) or nil,
    })
    if ok then
        log("settings: saved to " .. SETTINGS_FILE)
    else
        log("settings: SAVE FAILED - " .. tostring(err))
    end
end

local OBJECTIVES_MATCH = "objective"        -- WBP_ObjectivesPanel + its list-entry widgets
local NAVPOINTS_MATCH  = "navpoint"         -- WBP_Navpoints + WBP_NavpointObjective (waypoints + pickup markers)

-- Which keep-list is active right now (normal HUD vs crosshair-only),
-- augmented with any nav/objective groups the player has toggled back on.
local function current_keep()
    local base = crosshair_only and CROSSHAIR_ONLY_KEEP or KEEP
    local need_extra = (show_objectives or show_navpoints)
                    or (crosshair_only and KEEP_VISOR_LINES)
    if not need_extra then return base end
    local list = {}
    for _, v in ipairs(base) do list[#list + 1] = v end
    if show_objectives then list[#list + 1] = OBJECTIVES_MATCH end
    if show_navpoints  then list[#list + 1] = NAVPOINTS_MATCH  end
    if crosshair_only and KEEP_VISOR_LINES then
        for _, v in ipairs(VISOR_EXTRA) do list[#list + 1] = v end
        -- the TOP visor wire (VisorOverlayImage) is hosted INSIDE the shield
        -- bar; keep the bar's widget alive and prune_host() empties everything
        -- in it except the wire (see the VISOR HOST PRUNE section).
        list[#list + 1] = "shieldhealthbar"
    end
    return list
end

local function matches_any(name, list)
    for _, pat in ipairs(list) do
        if string.find(name, pat, 1, true) then return true end
    end
    return false
end

local function class_name(obj)
    local ok, cls = pcall(function() return obj:GetClass() end)
    if not ok or not cls then return nil end
    local ok2, full = pcall(function() return cls:GetFullName() end)
    if not ok2 then return nil end
    return full
end

local function short_name(obj)
    local n = "?"
    pcall(function() n = obj:GetFName():ToString() end)
    return n
end

local function short_class(obj)
    local c = "?"
    pcall(function() c = obj:GetClass():GetFName():ToString() end)
    return c
end

local function is_hud(name)
    return name ~= nil and string.find(name:lower(), HUD_PATH, 1, true) ~= nil
end

-- Walk an object's Outer chain looking for an owner whose name/class matches
-- one of `list`. Used to tell WHICH widget an action-glyph belongs to.
local function outer_has(obj, list, maxup)
    local cur = obj
    for _ = 1, maxup do
        local nxt
        pcall(function() nxt = cur:GetOuter() end)
        cur = nxt
        if not cur or not cur:IsValid() then break end
        local n = (short_name(cur) .. " " .. short_class(cur)):lower()
        if matches_any(n, list) then return true end
    end
    return false
end

-- Is this a cradle button-prompt glyph we want gone?
local function is_cradle_prompt(name, w)
    if not name then return false end
    if not string.find(name:lower(), "wbp_metui_actionwidget", 1, true) then return false end
    return outer_has(w, HIDE_ACTIONWIDGET_UNDER, 12)
end

-- Is a widget actually visible on screen (not Collapsed/Hidden)?
-- Defined HERE, high up, because find_hud_main() and the widget-tree code below
-- depend on it -- a `local function` referenced before its definition resolves
-- to a nil global and dies inside a pcall with no message.
local function is_shown(w)
    local v
    if pcall(function() v = w:IsVisible() end) and v ~= nil then
        return v == true
    end
    -- fallback: ESlateVisibility (1=Collapsed, 2=Hidden)
    if pcall(function() v = w:GetVisibility() end) and type(v) == "number" then
        return v ~= 1 and v ~= 2
    end
    return true
end

local function set_vis(w, vis)
    pcall(function()
        if w:IsValid() then
            w:SetVisibility(vis)
        end
    end)
end

--------------------------------------------------------------------
--  WIDGET-TREE TRAVERSAL (into WBP_HUD_Main and nested user widgets)
--------------------------------------------------------------------

local MAX_NODES = 4000
local node_count = 0

-- FindAllOf hands back three kinds of impostor for one live widget: the
-- class-default object ("Default__WBP_HUD_Main_C", empty WidgetTree), and --
-- after a level transition -- the PREVIOUS level's HUD_Main, which is still
-- valid and still has a walkable WidgetTree. Walking that dead tree hides
-- decorations on a HUD nobody can see, which is why loading a new level
-- brought back the cradle frames and backer boxes.
--
-- So require is_shown() too: only the live HUD renders. Ordering of the
-- fallbacks matters -- a shown-but-treeless widget still beats a stale one.
local function find_hud_main()
    local widgets = FindAllOf("UserWidget")
    if not widgets then return nil end
    local shown_no_tree, any_match
    for _, w in ipairs(widgets) do
        if w:IsValid() then
            local n = class_name(w)
            if n and string.find(n:lower(), "wbp_hud_main", 1, true)
               and not string.find(short_name(w):lower(), "default__", 1, true) then
                local root
                pcall(function()
                    local wt = w.WidgetTree
                    if wt and wt:IsValid() then root = wt.RootWidget end
                end)
                local live = is_shown(w)
                if root and root:IsValid() and live then return w end   -- ideal
                if live then shown_no_tree = shown_no_tree or w end
                any_match = any_match or w
            end
        end
    end
    return shown_no_tree or any_match
end

-- Walk a widget subtree. mode = "dump" prints; mode = "hide" collapses
-- anything whose name/class matches CHILD_HIDE.
local function traverse(w, depth, mode)
    if not w or not w:IsValid() or depth > 14 or node_count > MAX_NODES then return end
    node_count = node_count + 1

    local nm = short_name(w)
    local cls = short_class(w)

    if mode == "dump" then
        log(string.rep(". ", depth) .. nm .. "  [" .. cls .. "]")
    elseif mode == "hide" then
        local key = (nm .. " " .. cls):lower()
        if matches_any(key, CHILD_HIDE) then
            set_vis(w, VIS_COLLAPSED)
        elseif (not KEEP_VISOR_LINES) and matches_any(key, VISOR_CHILD) then
            set_vis(w, VIS_COLLAPSED)
        end
    elseif mode == "showvisor" then
        local key = (nm .. " " .. cls):lower()
        if matches_any(key, VISOR_CHILD) then
            set_vis(w, VIS_VISIBLE)
        end
    end

    -- descend into panel children
    local ok, count = pcall(function() return w:GetChildrenCount() end)
    if ok and type(count) == "number" and count > 0 then
        for i = 0, count - 1 do
            local child
            pcall(function() child = w:GetChildAt(i) end)
            if child then traverse(child, depth + 1, mode) end
        end
    end

    -- descend into a nested UserWidget's own tree
    pcall(function()
        local wt = w.WidgetTree
        if wt and wt:IsValid() then
            local root = wt.RootWidget
            if root and root:IsValid() then traverse(root, depth + 1, mode) end
        end
    end)
end

local function walk_hud(mode)
    node_count = 0
    local hud = find_hud_main()
    if not hud then
        if mode == "dump" then log("WBP_HUD_Main not found - are you in a mission?") end
        return
    end
    local started = false
    pcall(function()
        local wt = hud.WidgetTree
        if wt and wt:IsValid() then
            local root = wt.RootWidget
            if root and root:IsValid() then traverse(root, 0, mode); started = true end
        end
    end)
    if not started then traverse(hud, 0, mode) end
end

--------------------------------------------------------------------
--  VISOR HOST PRUNE  (crosshair-only + visor lines)
--
--  The TOP visor wire is VisorOverlayImage, hosted INSIDE
--  WBP_ShieldHealthBar (confirmed via the UE4SS object dump - its material
--  is MI_UI_HUDEcho_TopWire). Crosshair-only collapses the shield bar, which
--  takes the top wire with it. So in crosshair-only + visor mode we keep the
--  bar's widget visible but collapse every branch of its internal tree EXCEPT
--  the path leading to the wire. Collapsed branches record their previous
--  visibility and are restored when the mode ends; the wire's own ancestor
--  chain is forced open and left that way, since open is its normal state.
--------------------------------------------------------------------

local VISOR_HOST       = "shieldhealthbar"
local VISOR_HOST_CHILD = "visoroverlay"

local pruned = {}          -- addr -> { w = widget, vis = previous visibility }
local prune_active = false

-- FindAllOf returns the class-default object alongside the live widget --
-- "Default__WBP_ShieldHealthBar_C", whose WidgetTree is empty. It sorts first,
-- so taking the first match and breaking grabbed the CDO every time: set_vis on
-- it did nothing and the prune bailed on "no WidgetTree root", leaving the real
-- bar untouched. Require a usable WidgetTree so we can only pick a live one.
local function find_visor_host(widgets)
    local fallback
    for _, w in ipairs(widgets) do
        if w:IsValid() then
            local n = class_name(w)
            if n and string.find(n:lower(), VISOR_HOST, 1, true)
               and not string.find(short_name(w):lower(), "default__", 1, true) then
                local root
                pcall(function()
                    local wt = w.WidgetTree
                    if wt and wt:IsValid() then root = wt.RootWidget end
                end)
                if root and root:IsValid() then return w, root end
                fallback = fallback or w
            end
        end
    end
    return fallback, nil
end

local function prune_host(widgets)
    local host, root = find_visor_host(widgets)
    if not host then return end
    -- apply() only SKIPS keepers, it never re-shows them, so a bar collapsed
    -- while visor was off is still collapsed when it becomes a keeper again.
    -- This is the one place that re-opens it.
    set_vis(host, VIS_VISIBLE)
    if not root then return end

    -- locate the wire inside the host's tree
    local wire
    local function locate(w, depth)
        if wire or not w or not w:IsValid() or depth > 12 then return end
        if string.find(short_name(w):lower(), VISOR_HOST_CHILD, 1, true) then wire = w; return end
        local ok, cnt = pcall(function() return w:GetChildrenCount() end)
        if ok and type(cnt) == "number" then
            for i = 0, cnt - 1 do
                local c
                pcall(function() c = w:GetChildAt(i) end)
                locate(c, depth + 1)
            end
        end
    end
    locate(root, 0)
    if not wire then return end

    -- the wire + its ancestors stay; everything else is collapsed
    local keep, chain = {}, {}
    local cur = wire
    while cur and cur:IsValid() do
        local a
        pcall(function() a = cur:GetAddress() end)
        if a then keep[a] = true end
        chain[#chain + 1] = cur
        local p
        pcall(function() p = cur:GetParent() end)
        cur = p
    end
    -- Fail safe: if the walk never got past the wire we can't tell its ancestors
    -- from its siblings, and pruning would collapse its own parents. Leave the
    -- bar alone rather than hide the very thing we're here to show.
    if #chain < 2 then return end

    local function prune(w, depth)
        if not w or not w:IsValid() or depth > 12 then return end
        local a
        pcall(function() a = w:GetAddress() end)
        if a and not keep[a] then
            if not pruned[a] then
                local pv
                pcall(function() pv = w:GetVisibility() end)
                pruned[a] = { w = w, vis = pv }
            end
            set_vis(w, VIS_COLLAPSED)
            return   -- whole branch is gone; no need to descend
        end
        local ok, cnt = pcall(function() return w:GetChildrenCount() end)
        if ok and type(cnt) == "number" then
            for i = 0, cnt - 1 do
                local c
                pcall(function() c = w:GetChildAt(i) end)
                prune(c, depth + 1)
            end
        end
    end
    prune(root, 0)
    -- Sparing an ancestor is not the same as showing it. A visor-off pass can
    -- leave a panel between the root and the wire collapsed, and nothing else
    -- ever re-opens it -- the wire then renders inside a collapsed parent, i.e.
    -- not at all (this is why the top wire went missing after an off/on cycle
    -- while the bottom one, which has no host in between, came back fine).
    -- These panels are visible during normal play, so forcing them open is also
    -- their correct resting state; they're deliberately not recorded in `pruned`.
    for _, node in ipairs(chain) do set_vis(node, VIS_VISIBLE) end
    set_vis(wire, VIS_VISIBLE)
    pcall(function() wire:SetRenderOpacity(1.0) end)
    prune_active = true
end

local function unprune_host()
    if not prune_active then return end
    for _, rec in pairs(pruned) do
        pcall(function()
            if rec.w:IsValid() then
                rec.w:SetVisibility(rec.vis ~= nil and rec.vis or VIS_VISIBLE)
            end
        end)
    end
    pruned = {}
    prune_active = false
end

--------------------------------------------------------------------
--  TOP-LEVEL HIDE PASS
--------------------------------------------------------------------

local function report_keeper(w, name)
    if reported[name] then return end
    reported[name] = true
    local slotinfo = "slot=?"
    pcall(function()
        local slot = w.Slot
        if slot and slot:IsValid() then slotinfo = "slot=" .. (class_name(slot) or "?")
        else slotinfo = "slot=none" end
    end)
    log("KEEP  " .. name .. "  " .. slotinfo)
end

--------------------------------------------------------------------
--  OG AMMO  (AR + pistol style: hide the magazine number and the "/"
--  separator, keep only the reserve counter.)
--
--  The cradle text widgets can't tell weapon types apart (the game marks the "/"
--  AND "%" "visible" for both ballistic and charge). The reliable signal is
--  STRUCTURAL: energy weapons each render their OWN reticle widget
--  (WBP_WeaponAim_Scope_BeamRifle / _Plasma / _Needler -- see CHARGE_RETICLES),
--  and only the ACTIVE weapon's reticle is shown. Human weapons use different
--  reticles, so an energy reticle on screen == a charge weapon is up, with no
--  false-positive on the AR or human sniper. Charge up -> keep the mag field
--  visible (it holds the "NN%" value); otherwise -> hide the mag numbers. The
--  "/" is hidden with render opacity. (A shown numeric charge readout is kept as
--  a secondary fallback for the plasma.)
--
--  The reserve number ships faded; we brighten it via the RESERVE_HIJACK hook
--  further down (we intercept the game's own color set and swap in bright cyan),
--  which is the only flicker-free way to do it at runtime.
--------------------------------------------------------------------

local OG_AMMO = true               -- ON: OG-style ammo on AR/pistol (mag+"/" hidden,
                                   -- reserve kept). Charge weapons (plasma/beam) left intact.
local RESERVE_HIJACK  = true       -- brighten the faded reserve by intercepting the game's
                                   -- OWN color set and swapping dim->bright before it runs,
                                   -- so the game paints bright itself = no flicker, no loop.
local RESERVE_COLOR = { R = 0.40, G = 0.90, B = 1.0, A = 1.0 }  -- glowy cyan (tweak me)

-- Charge weapons keep their "NN%" readout; we spot them by RETICLE:
--   * energy RANGED weapons each show their own reticle (beam rifle, plasma) --
--     if one of these is on screen, a charge weapon is up;
--   * the energy SWORD is melee -> it shows NO reticle at all, whereas every gun
--     (incl. the mag-fed Needler) shows SOME reticle (its own or the Shared one).
-- So "an energy reticle is shown, OR no reticle at all is shown" == charge weapon.
local CHARGE_RETICLES = {   -- energy ranged weapons' own reticles
    "WBP_WeaponAim_Scope_BeamRifle_C",
    "WBP_WeaponAim_Scope_Plasma_C",
    "WBP_WeaponAim_Scope_Beam_C",       -- Sentinel Beam: battery, shows "NN%"
}
-- EVERY weapon reticle the game ships (enumerated from the UE4SS object dump:
-- /Game/UI/Hud/Reticle/Widgets/). This list must stay exhaustive -- the melee
-- test is "no reticle at all is shown", so ANY reticle missing here makes its
-- weapon look like a charge weapon and wrongly keeps the magazine number. That
-- was the rocket-launcher bug: SPNKr wasn't listed, so it fell through as melee.
local ALL_RETICLES = {
    "WBP_WeaponAim_Scope_Shared_C",     -- (first: the common one, for early-out)
    "WBP_WeaponAim_Scope_BeamRifle_C",  "WBP_WeaponAim_Scope_Plasma_C",
    "WBP_WeaponAim_Scope_Needler_C",    "WBP_WeaponAim_Scope_Sniper_C",
    "WBP_WeaponAim_Scope_Magnum_C",     -- Magnum: ballistic (its own reticle)
    "WBP_WeaponAim_Scope_SPNKr_C",      -- rocket launcher
    "WBP_WeaponAim_Scope_Spike_C",      -- Spiker
    "WBP_WeaponAim_Scope_NeedleRifle_C",
    "WBP_WeaponAim_Scope_FuelRod_C",
    "WBP_WeaponAim_Scope_Beam_C",       -- Sentinel Beam
    "WBP_WeaponAim_Scope_HeatMeter_C",  -- overheat readout (rides with plasma)
    "WBP_WeaponAim_Scope_SpaceHUD_C",   -- vehicle / space sections
    "WBP_WeaponAim_Scope_Base_C",       -- base class, in case it's ever used bare
}

local function outer_addr(w)
    local a = nil
    pcall(function()
        local o = w:GetOuter()
        if o and o:IsValid() then a = o:GetAddress() end
    end)
    return a
end

local function widget_text(w)
    local s = nil
    pcall(function() s = w:GetText():ToString() end)
    return s
end

-- Exact widget names for the MAIN weapon cradle, confirmed from in-game F8
-- dumps. We manage only these (not the scope readout).
local MAG_NAMES = {   -- magazine / current-count fields (HIDE for ballistic)
    ["currentammocounttextblock"]         = true,
    ["currentammoleadingzeroestextblock"] = true,
    ["halouinumerictextblock_ammocurrent"] = true,  -- Magnum's magazine field
}
local RES_NAMES = {   -- reserve / max field (KEEP + brighten)
    ["maxammocounttextblock"] = true,
    ["halouinumerictextblock_ammototal"] = true,    -- Magnum's reserve field
}
local SLASH_NAMES = {  -- the "/" separator (hidden via render opacity, not collapse)
    ["ammoseparatortextblock"] = true,
}

local function is_reserve_name(n) return RES_NAMES[n] == true end
local function is_mag_name(n)     return MAG_NAMES[n] == true end

-- Build the combined pool of text/number widgets.
-- PERF: this ran TWO full-UObject-array scans every 16ms tick (~125 scans/s).
-- The text blocks are persistent objects, so the pool is cached and refreshed
-- on a slow cadence; every user of the pool already guards with IsValid(), so
-- stale entries between refreshes are harmless. A brand-new block (first HUD
-- build of a mission) is picked up within a refresh interval, and the
-- SetColorAndOpacity hook paints its mag number transparent in the meantime.
local pool_cache
local pool_refresh_tick = 0
local POOL_REFRESH_TICKS = 16    -- ~256ms at the 16ms loop rate

local function ammo_pool()
    pool_refresh_tick = pool_refresh_tick + 1
    if pool_cache and (pool_refresh_tick % POOL_REFRESH_TICKS) ~= 1 then
        return pool_cache
    end
    local pool = {}
    local a = FindAllOf("HaloUINumericTextBlock")
    if a then for _, t in ipairs(a) do pool[#pool + 1] = t end end
    local b = FindAllOf("HaloUITextBlock")
    if b then for _, t in ipairs(b) do pool[#pool + 1] = t end end
    pool_cache = pool
    return pool
end

local function is_slash(t, n) return SLASH_NAMES[n] == true end

local function has_digit(s) return s ~= nil and string.find(s, "%d") ~= nil end

-- A "%" widget (used only by the F8 diagnostic tag).
local function is_percent(t, n)
    return string.find(n, "percent", 1, true) ~= nil
        or (widget_text(t) or ""):gsub("%s", "") == "%"
end

-- Bring the mag number(s) + "/" back (mod-toggle-off). Un-collapse the mag and
-- restore the separator's render opacity.
local function restore_og_ammo()
    for _, t in ipairs(ammo_pool()) do
        if t:IsValid() then
            local n = short_name(t):lower()
            if is_mag_name(n) then set_vis(t, VIS_VISIBLE) end
            if is_slash(t, n) then pcall(function() t:SetRenderOpacity(1.0) end) end
        end
    end
end

-- true if any of the given weapon-reticle classes has a SHOWN instance.
--
-- PERF: FindAllOf scans the entire UObject array (~395k entries), and this used
-- to run one scan PER CLASS per call -- with 13 classes on the fast loop that
-- alone saturated the Lua thread and made hotkeys lag by ~1s. Reticle widgets
-- are persistent objects, so instances are CACHED per class and only the cheap
-- IsValid/is_shown checks run per call. The cache is cleared every couple of
-- seconds (see apply_og_ammo) so classes that don't exist yet -- e.g. the
-- needler reticle before you first pick one up -- get re-scanned and found.
local reticle_cache = {}    -- cls -> array of instances (possibly empty)

local function clear_reticle_cache() reticle_cache = {} end

-- Do any reticle widgets EXIST at all, shown or not?
--
-- This distinguishes two states that both look like "no reticle is shown" but
-- mean opposite things:
--   * HUD still building on level load  -> no reticle widgets exist yet
--   * a melee weapon (energy sword)     -> reticles exist, none is shown
-- Only the second should keep the magazine number visible. Without this check
-- the melee rule fired during every load and the mag sat on screen for several
-- seconds until the first reticle appeared.
local function reticle_any_exist(classes)
    for _, cls in ipairs(classes) do
        local list = reticle_cache[cls]
        if not list then
            list = FindAllOf(cls) or {}
            reticle_cache[cls] = list
        end
        for _, w in ipairs(list) do
            if w:IsValid() then return true end
        end
    end
    return false
end

local function reticle_shown(classes, force_fresh)
    for _, cls in ipairs(classes) do
        local list = (not force_fresh) and reticle_cache[cls] or nil
        -- A cached instance going invalid means the widget was destroyed (and
        -- probably rebuilt, e.g. on a weapon swap). Drop the entry and rescan,
        -- or we'd keep reporting "not shown" for a reticle that now exists.
        if list then
            for _, w in ipairs(list) do
                if not w:IsValid() then list = nil; break end
            end
        end
        if not list then
            list = FindAllOf(cls) or {}
            reticle_cache[cls] = list
        end
        for _, w in ipairs(list) do
            if w:IsValid() and is_shown(w) then return true end
        end
    end
    return false
end

-- Latest weapon-type verdict, cached so the SetColorAndOpacity hijack (below) can
-- decide whether to zero the magazine number without recomputing. Updated every
-- apply_og_ammo pass (~16ms). false = ballistic (hide mag), true = charge (keep).
local last_charge_up = false

-- The overheat meter (WBP_WeaponCooldownBar) lives under WeaponCradle, so the
-- "weaponcradle" keeper match keeps it alive for EVERY weapon -- including
-- ballistics, which never overheat and so leave it drawn as an empty outlined
-- bar. Only energy weapons overheat, so gate it on the same charge signal the
-- ammo logic already computes. Set false to keep the bar on all weapons.
local HIDE_COOLDOWN_ON_BALLISTIC = true

-- Weapon-type classification is the EXPENSIVE half of this function:
-- reticle_shown() runs a FindAllOf per class, and FindAllOf scans the entire
-- UObject array (~395k entries). At the 16ms loop rate that was up to 16 full
-- scans per tick, ~1000/second -- enough to saturate the Lua thread and leave
-- hotkeys queued behind it for ~1s. Weapon swaps take far longer than 100ms, so
-- re-classifying every 6th tick is imperceptible and ~6x cheaper. The CHEAP half
-- (driving mag/slash visibility) still runs every tick, so the anti-flash
-- behaviour this loop exists for is unchanged.
local og_tick = 0
local RETICLE_RECHECK_TICKS = 6     -- ~100ms at the 16ms loop rate

local function apply_og_ammo()
    if not OG_AMMO then return end
    local pool = ammo_pool()

    og_tick = og_tick + 1
    -- Periodically drop the reticle instance cache so not-yet-created reticle
    -- classes (first pickup of a weapon type) get one fresh scan and appear.
    if (og_tick % 125) == 0 then clear_reticle_cache() end
    if og_tick == 1 or (og_tick % RETICLE_RECHECK_TICKS) == 0 then
        -- PRIMARY signal (structural, by reticle): an energy RANGED reticle is on
        -- screen (beam/plasma), OR NO weapon reticle is on screen at all (the melee
        -- energy sword). Either means a charge weapon whose "NN%" must stay visible.
        -- The AR/human sniper/Needler all show a reticle that ISN'T an energy one, so
        -- they're correctly treated as ballistic.
        -- "No reticle on screen at all" is the ONLY signal that keeps the
        -- magazine number visible, so a false negative here un-hides it -- which
        -- is exactly what a stale cache produced right after a weapon swap.
        -- Before flipping ballistic -> charge, confirm with an UNCACHED scan.
        -- Gated on last_charge_up so this only costs a rescan on the transition,
        -- not continuously while a genuine charge weapon is held.
        local verdict
        if not reticle_any_exist(ALL_RETICLES) then
            -- HUD hasn't built its reticles yet (level load). The melee rule
            -- below would misread this as a charge weapon, so hold BALLISTIC:
            -- mag hidden, which is right for every weapon but the sword and
            -- self-corrects the moment a real reticle appears.
            verdict = false
        else
            local any_reticle = reticle_shown(ALL_RETICLES)
            if (not any_reticle) and (not last_charge_up) then
                any_reticle = reticle_shown(ALL_RETICLES, true)
            end
            verdict = reticle_shown(CHARGE_RETICLES) or (not any_reticle)
            -- FALLBACK: the plasma also exposes a shown numeric charge readout.
            if not verdict then
                for _, t in ipairs(pool) do
                    if t:IsValid() and string.find(short_name(t):lower(), "charge", 1, true)
                            and is_shown(t) and has_digit(widget_text(t)) then
                        verdict = true
                        break
                    end
                end
            end
        end
        last_charge_up = verdict
    end
    local charge_up = last_charge_up

    for _, t in ipairs(pool) do
        if t:IsValid() then
            local n = short_name(t):lower()
            if is_slash(t, n) then pcall(function() t:SetRenderOpacity(0.0) end) end
        end
    end

    local vis = charge_up and VIS_VISIBLE or VIS_COLLAPSED
    local op  = charge_up and 1.0 or 0.0
    for _, t in ipairs(pool) do
        if t:IsValid() and is_mag_name(short_name(t):lower()) then
            set_vis(t, vis)
            -- ALSO drive render opacity (like the "/" separator, which never
            -- flashes): a collapse is undone the instant the game re-shows the
            -- widget on a weapon swap, but a 0 render-opacity tends to persist
            -- through that transition, covering the frame the color hook misses.
            pcall(function() t:SetRenderOpacity(op) end)
            -- NOTE: everything else we tried to further hide/soften the mag flash
            -- destabilized the game and was removed. Constructing a color struct and
            -- CALLING SetColorAndOpacity from this async loop (for the "dark blip")
            -- caused a rare struct-marshal crash; font-size-0 crashed; SetVisibility
            -- and SetText hooks crashed. The reserve HOOK below is safe because it
            -- only MUTATES an existing struct param in place, never constructs one.
            -- So the mag is hidden the crash-proof way -- collapse + render-opacity --
            -- and the reserve/mag alpha is handled in that hook. The occasional
            -- ~1-frame equip flash is the accepted, stable floor.
        end
    end

    -- Overheat meter: only meaningful on energy weapons (see the flag above).
    -- Runs in this same ~16ms pass so it tracks weapon swaps without a lag.
    if HIDE_COOLDOWN_ON_BALLISTIC then
        local bars = FindAllOf("WBP_WeaponCooldownBar_C")
        if bars then
            for _, b in ipairs(bars) do
                if b:IsValid() then set_vis(b, vis) end
            end
        end
    end
end

--------------------------------------------------------------------
--  NAV MARKER BACKING BOX
--
--  Navpoint distance text ("16 m") sits INSIDE a HaloUIBorder_0 that draws the
--  black rounded backing box (tree-dump confirmed: Border > DistanceTextBlock).
--  Collapsing the border would take the text with it, and render opacity
--  propagates to children -- so instead the border's own background brush is
--  tinted fully transparent. SetBrushColor takes a flat float FLinearColor,
--  the same crash-safe marshal shape as the {X,Y} vectors used for
--  scale/translate (NOT the nested FSlateColor construction that crashed).
--------------------------------------------------------------------

local NAV_BORDER_HIDE = true      -- false = keep the game's black backing box
local nav_border_cache = {}
local nav_border_tick = 0

local function hide_nav_borders()
    if not NAV_BORDER_HIDE then return end
    -- Rescan on a slow cadence (or while empty); borders persist, so per-pass
    -- work is normally just the cheap re-tint of known instances.
    nav_border_tick = nav_border_tick + 1
    if (#nav_border_cache == 0) or (nav_border_tick % 5) == 1 then
        nav_border_cache = {}
        local borders = FindAllOf("HaloUIBorder")
        if borders then
            for _, b in ipairs(borders) do
                if b:IsValid()
                   and string.find(short_name(b):lower(), "halouiborder_0", 1, true)
                   and outer_has(b, { "navpoint" }, 6) then
                    nav_border_cache[#nav_border_cache + 1] = b
                end
            end
        end
    end
    for _, b in ipairs(nav_border_cache) do
        if b:IsValid() then
            pcall(function() b:SetBrushColor({ R = 0, G = 0, B = 0, A = 0.0 }) end)
        end
    end
end

--------------------------------------------------------------------
--  CE GRENADES RIGHT  (grenades + equipment -> top-right corner)
--
--  Grenades CANNOT be translated to the right side: their grid gives each
--  child a snug auto-sized cell and translating outside it gets clipped
--  (this is why the early +420 nudge made them vanish). But reparenting is
--  mechanically proven (slot calls all succeeded in the grid experiment), and
--  the perfect destination exists: the weapon cradle's original right-side
--  HorizontalBox -- the container that anchored the ammo to the top-right
--  corner all game. Moving the grenades into it inherits that anchoring for
--  free, on every resolution. Checked every pass so HUD rebuilds re-apply.
--------------------------------------------------------------------

local ce_diag_seen = {}
local function ce_diag(msg)
    if not ce_diag_seen[msg] then ce_diag_seen[msg] = true; log("CEPOS " .. msg) end
end

local function ce_grenades_right(widgets)
    if not CE_LAYOUT then return end

    -- SHOWN only (stale instances from old levels also match), and EXACT class
    -- names: the asset folder is /Game/UI/Hud/WeaponCradle/, so a bare
    -- "weaponcradle" substring also matches WBP_AmmoPickupBanner and
    -- WBP_WeaponCooldownBar that live in it -- and first-match single-target
    -- operations then grab the wrong widget entirely. (Likely what the earlier
    -- grid experiment actually did.) The _C class suffix disambiguates.
    local wc, gc, eq
    for _, w in ipairs(widgets) do
        if w:IsValid() and is_shown(w) then
            local n = class_name(w)
            if n then
                local ln = n:lower()
                if not string.find(short_name(w):lower(), "default__", 1, true) then
                    if not wc and string.find(ln, "wbp_weaponcradle_c", 1, true) then wc = w end
                    if not gc and string.find(ln, "wbp_grenadecradle_c", 1, true) then gc = w end
                    if not eq and string.find(ln, "wbp_equipmenticon_c", 1, true) then eq = w end
                end
            end
        end
    end
    if not (wc and gc) then return end

    local okrun, errrun = pcall(function()
        -- the cradle may be wrapped (CommonVisualAttachment etc.); walk up a
        -- few levels to the HorizontalBox rather than trusting the direct parent
        local hbox
        local cur = wc
        for _ = 1, 5 do
            local p
            pcall(function() p = cur:GetParent() end)
            if not p or not p:IsValid() then break end
            if string.find(short_class(p):lower(), "horizontalbox", 1, true) then hbox = p; break end
            cur = p
        end
        if not hbox then ce_diag("bail: no HorizontalBox within 5 levels above the cradle"); return end

        local function move_in(w, label)
            local cur
            pcall(function() cur = w:GetParent() end)
            if cur and cur:IsValid() and cur:GetAddress() == hbox:GetAddress() then return false end
            local slot = hbox:AddChildToHorizontalBox(w)
            if not slot or not slot:IsValid() then
                ce_diag("FAILED: AddChildToHorizontalBox(" .. label .. ") returned no slot")
                return false
            end
            pcall(function() slot:SetVerticalAlignment(1) end)                 -- top
            pcall(function() slot:SetPadding({ Left = 18, Top = 0, Right = 0, Bottom = 0 }) end)
            return true
        end

        if move_in(gc, "grenades") then
            -- apply the edge-pack nudge on the move event. 375/0 is user-tap-
            -- verified (see CE_GREN defaults note); computed values repeatedly
            -- landed past the box's clip edge and vanished the grenades. If a
            -- user tunes past the edge themselves, Ctrl+Alt+Left still applies
            -- live, so an invisible cradle is always tap-recoverable.
            local t = TRANSLATE["grenadecradle"]
            if t then t.x = CE_GREN_X; t.y = CE_GREN_Y end
            log("CEPOS grenades moved into the right-side weapon box")
        end
        if eq and move_in(eq, "equipment") then
            local t = TRANSLATE["equipmenticon"]
            if t then t.x = CE_GREN_X; t.y = CE_GREN_Y end
        end
    end)
    if not okrun then ce_diag("inner error: " .. tostring(errrun)) end
end

local function apply()
    local widgets = FindAllOf("UserWidget")
    if not widgets then return 0, 0 end
    local hidden, kept = 0, 0
    -- Hoisted: current_keep() ALLOCATES AND COPIES a fresh table on every call
    -- whenever any opt-in group is active. Calling it inside the loop meant one
    -- allocation per widget per pass, several hundred per apply(). The list is
    -- constant for the duration of the pass.
    local keep_list = current_keep()
    for _, w in ipairs(widgets) do
        if w:IsValid() then
            local name = class_name(w)
            if is_hud(name) then
                local lname = name:lower()
                if matches_any(lname, LEAVE_TO_GAME) then
                    -- hands off entirely -- the game owns this one
                elseif matches_any(lname, NEVER_TOUCH) then
                    -- container: leave visible, but hide its baked-in pieces
                elseif matches_any(lname, keep_list) then
                    -- Shift+C: hide the reticle even though it's a keeper
                    if hide_crosshair and string.find(lname, "reticle", 1, true) then
                        set_vis(w, VIS_COLLAPSED); hidden = hidden + 1
                    else
                        kept = kept + 1
                        report_keeper(w, name)
                    end
                else
                    set_vis(w, VIS_COLLAPSED); hidden = hidden + 1
                end
            elseif name and (matches_any(name:lower(), EXTRA_HIDE)
                    or ((not KEEP_VISOR_LINES) and matches_any(name:lower(), VISOR_EXTRA))) then
                set_vis(w, VIS_COLLAPSED); hidden = hidden + 1
            end
            -- independent: cradle button-prompt glyphs (equipment "G", etc.)
            if is_cradle_prompt(name, w) then
                set_vis(w, VIS_COLLAPSED); hidden = hidden + 1
            end
        end
    end
    -- OG ammo: hide mag + "/" on ballistic weapons (AR/pistol), keep reserve
    local oka, ea = pcall(apply_og_ammo)
    if not oka then log("og-ammo error: " .. tostring(ea)) end

    -- nav marker backing box -> transparent (see NAV MARKER BACKING BOX above)
    local okn, en = pcall(hide_nav_borders)
    if not okn then log("nav-border error: " .. tostring(en)) end

    -- CE layout: grenades + equipment live in the right-side weapon box
    local okg, eg = pcall(ce_grenades_right, widgets)
    if not okg then log("ce-grenades error: " .. tostring(eg)) end


    -- hide baked-in internal pieces (CHILD_HIDE, plus visor pieces when clean)
    walk_hud("hide")

    -- crosshair-only + visor ON: actively restore visor elements.
    -- (NOTE: show_visor() is defined later in the file, so calling it here was
    -- a nil-global error at runtime. Inlined instead.)
    if crosshair_only and KEEP_VISOR_LINES then
        for _, w in ipairs(widgets) do
            if w:IsValid() then
                local n = class_name(w)
                if n and matches_any(n:lower(), VISOR_EXTRA) then
                    set_vis(w, VIS_VISIBLE)
                end
            end
        end
        walk_hud("showvisor")
        -- TOP wire: empty the shield bar down to just VisorOverlayImage
        local okp, ep = pcall(prune_host, widgets)
        if not okp then log("visor-prune error: " .. tostring(ep)) end
    else
        -- leaving the mode: put the shield bar's internals back how they were
        pcall(unprune_host)
    end

    return hidden, kept
end

-- Reposition OverlaySlot elements per the MOVE table (snap to corner/edge).
local function apply_moves()
    if next(MOVE) == nil then return end   -- table ships empty; skip the scan
    local widgets = FindAllOf("UserWidget")
    if not widgets then return end
    for _, w in ipairs(widgets) do
        if w:IsValid() then
            local n = class_name(w)
            if n then
                local ln = n:lower()
                for key, m in pairs(MOVE) do
                    if string.find(ln, key, 1, true) then
                        pcall(function()
                            local slot = w.Slot
                            if slot and slot:IsValid() then
                                local sc = (class_name(slot) or ""):lower()
                                if string.find(sc, "overlayslot", 1, true) then
                                    if m.h then slot:SetHorizontalAlignment(m.h) end
                                    if m.v then slot:SetVerticalAlignment(m.v) end
                                end
                            end
                        end)
                    end
                end
            end
        end
    end
end

-- HUD SCALE: scale the persistent HUD elements by HUD_SCALE. RenderScale is a
-- render-only transform (no layout reflow) around each element's own centre, so
-- each piece scales in place and stays anchored to its corner. Same crash-safe flat
-- {X,Y} vector marshal apply_translates uses. Applied every enforce pass so it
-- persists, and immediately on a hotkey change.
local function apply_hud_scale()
    local widgets = FindAllOf("UserWidget")
    if not widgets then return end
    for _, w in ipairs(widgets) do
        if w:IsValid() then
            local n = class_name(w)
            if n then
                local ln = n:lower()
                for _, key in ipairs(SCALE_TARGETS) do
                    if string.find(ln, key, 1, true) then
                        pcall(function()
                            local piv = SCALE_PIVOT[key]
                            if piv then w:SetRenderTransformPivot({ X = piv.x, Y = piv.y }) end
                            -- CE layout: MIRROR the weapon cradle (negative X
                            -- scale) so its right-handed composition faces left.
                            -- Text inside is counter-flipped below so numbers
                            -- still read normally. Same flat {X,Y} marshal.
                            local sx = HUD_SCALE
                            if CE_LAYOUT and key == "weaponcradle" then sx = -HUD_SCALE end
                            w:SetRenderScale({ X = sx, Y = HUD_SCALE })
                        end)
                        break
                    end
                end
            end
        end
    end

    -- Counter-flip the ammo text blocks inside the mirrored cradle: a second
    -- X=-1 mirror cancels the parent's, so digits render un-reversed. Applies
    -- to mag + reserve + separator (mag holds the visible "NN%" on charge
    -- weapons, so it needs the fix too even though it's hidden on ballistics).
    if CE_LAYOUT then
        for _, t in ipairs(ammo_pool()) do
            if t:IsValid() then
                local n = short_name(t):lower()
                if is_mag_name(n) or is_reserve_name(n) or is_slash(t, n) then
                    pcall(function()
                        t:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
                        t:SetRenderScale({ X = -1.0, Y = 1.0 })
                    end)
                end
            end
        end
    end
end

-- Nudge elements by a pixel offset (RenderTranslation) per the TRANSLATE table.
local function apply_translates()
    local widgets = FindAllOf("UserWidget")
    if not widgets then return end
    for _, w in ipairs(widgets) do
        if w:IsValid() then
            local n = class_name(w)
            if n then
                local ln = n:lower()
                for key, t in pairs(TRANSLATE) do
                    if string.find(ln, key, 1, true) then
                        pcall(function() w:SetRenderTranslation({ X = t.x, Y = t.y }) end)
                    end
                end
            end
        end
    end
end

local function restore_all()
    local widgets = FindAllOf("UserWidget")
    if not widgets then return end
    for _, w in ipairs(widgets) do
        if w:IsValid() then
            local n = class_name(w)
            if n then
                local ln = n:lower()
                -- Do NOT re-show the black backer boxes / dividers (EXTRA_HIDE):
                -- the game keeps those hidden during play, so force-showing them
                -- on mod-off produced ugly black boxes vanilla never displays.
                -- Restore everything else (real HUD + the visor frame).
                if matches_any(ln, LEAVE_TO_GAME) then
                    -- hands off: don't force-show what the game may be
                    -- deliberately hiding (e.g. hit markers turned off)
                elseif matches_any(ln, EXTRA_HIDE) then
                    -- leave hidden -- this is what vanilla actually looks like
                elseif is_hud(n) or matches_any(ln, VISOR_EXTRA) then
                    set_vis(w, VIS_VISIBLE)
                end
            end
        end
    end
    -- bring the OG-ammo bits (mag number + "/") back when toggling off
    restore_og_ammo()
end

-- Reveal the visor "line" decorations (top-level + nested pieces).
local function show_visor()
    local widgets = FindAllOf("UserWidget")
    if widgets then
        for _, w in ipairs(widgets) do
            if w:IsValid() then
                local n = class_name(w)
                if n and matches_any(n:lower(), VISOR_EXTRA) then set_vis(w, VIS_VISIBLE) end
            end
        end
    end
    walk_hud("showvisor")   -- the pieces nested inside the HUD
end

--------------------------------------------------------------------
--  DUMPS
--------------------------------------------------------------------

local function dump_widgets()
    local widgets = FindAllOf("UserWidget")
    if not widgets then log("No UserWidgets - are you in a mission?") return end
    local seen = {}
    log("---- live UserWidget classes (dump) ----")
    for _, w in ipairs(widgets) do
        if w:IsValid() then
            local n = class_name(w)
            if n and not seen[n] then seen[n] = true; log(n) end
        end
    end
    log("---- end dump ----")
end

local function layout_report()
    reported = {}
    log("---- KEEPER LAYOUT REPORT ----")
    local _, kept = apply()
    log("---- end report (" .. kept .. " keepers) ----")
end

local function tree_dump()
    log("======== WBP_HUD_Main TREE DUMP ========")
    walk_hud("dump")
    log("======== end tree (" .. node_count .. " nodes) ========")
end

--------------------------------------------------------------------
--  HOTKEYS
--------------------------------------------------------------------

-- (INS master toggle removed: rebuilding the game's exact vanilla HUD from Lua
--  isn't reliable -- the game redraws its own elements on its own schedule, so
--  a runtime "restore" always leaves stray boxes/prompts. The mod just stays on.
--  To see true vanilla, disable the mod file: rename enabled.txt in the
--  CleanImmersiveUI folder, or pull the folder out of Mods, and relaunch.)

RegisterKeyBind(KEY_CROSSHAIR, KEY_CROSSHAIR_MODS, function()
    crosshair_only = not crosshair_only
    enabled = true                 -- crosshair mode implies the mod is active
    restore_all()                  -- reset visibility baseline...
    apply()                        -- ...then re-apply for the current mode
    -- restore_all() force-shows the interact/pickup prompt even when no weapon
    -- is nearby (the same phantom-prompt problem the N handler avoids). Collapse
    -- it here; the game re-shows it on the next pickup-range event.
    local widgets = FindAllOf("UserWidget")
    if widgets then
        for _, w in ipairs(widgets) do
            if w:IsValid() then
                local n = class_name(w)
                if n and string.find(n:lower(), "interactprompt", 1, true) then
                    set_vis(w, VIS_COLLAPSED)
                end
            end
        end
    end
    if crosshair_only then
        log("CROSSHAIR-ONLY mode ON - everything hidden but the reticle. Ctrl+Shift+H to restore.")
    else
        log("CROSSHAIR-ONLY mode OFF - back to the normal clean HUD.")
    end
    save_current()
end)

RegisterKeyBind(KEY_VISOR, KEY_VISOR_MODS, function()
    local ok, err = pcall(function()
        KEEP_VISOR_LINES = not KEEP_VISOR_LINES
        enabled = true
        if KEEP_VISOR_LINES then show_visor() end  -- reveal the visor pieces...
        apply()                                    -- ...then re-assert everything else
        if KEEP_VISOR_LINES then
            log("VISOR LINES ON - Halo-3-style frame/wires restored. Ctrl+Shift+V to clean.")
        else
            log("VISOR LINES OFF - back to the clean HUD.")
        end
        save_current()
    end)
    if not ok then log("visor toggle error: " .. tostring(err)) end
end)

-- Nav / objectives reveal toggles.
--   Ctrl+Shift+N : objectives + navpoints/waypoints + pickup markers (as a group)
--   Shift+N      : navpoints/waypoints (+ pickup markers) only
-- Both keys share the N key, so we coalesce: whichever handler fires first
-- schedules the action after a short delay; if the Ctrl+Shift variant also
-- fires (in either order) it flags the group intent. This makes the two binds
-- behave distinctly even if the loader delivers both on a single press.
local n_pending = false
local n_group   = false

-- Show/hide only the widgets matching `match` (leaves everything else alone, so
-- we don't force-show unrelated keepers like the interact prompt). One cheap
-- FindAllOf pass -- far quicker than a full apply(), which is what makes the
-- nav toggle feel instant. Defaults to revealing.
local function set_group_vis(match, vis)
    vis = vis or VIS_VISIBLE          -- (0 is truthy in Lua, so this is safe)
    local widgets = FindAllOf("UserWidget")
    if not widgets then return end
    for _, w in ipairs(widgets) do
        if w:IsValid() then
            local n = class_name(w)
            if n and string.find(n:lower(), match, 1, true) then
                set_vis(w, vis)
            end
        end
    end
end

local function process_n()
    if n_group then
        -- toggle objectives + nav together (on unless both already on)
        local target = not (show_objectives and show_navpoints)
        show_objectives = target
        show_navpoints  = target
        log((target and "NAV+OBJECTIVES ON" or "NAV+OBJECTIVES OFF")
            .. " - Ctrl+Shift+N to toggle, Shift+N for waypoints only.")
    else
        show_navpoints = not show_navpoints
        log((show_navpoints and "WAYPOINTS ON" or "WAYPOINTS OFF")
            .. " - Shift+N to toggle.")
    end
    enabled = true

    -- Release the coalescing latch BEFORE the slow work below. apply() measures
    -- ~1.1s in-game, and the latch used to stay set for that whole window, so a
    -- second press in that time was silently dropped -- press, see nothing,
    -- press again, and you'd just toggle straight back. That was the "have to
    -- press it twice" bug. Coalescing still works: it only needs to cover the
    -- 60ms window before this runs.
    n_pending = false
    n_group   = false

    -- Drive visibility DIRECTLY, both ways, before the expensive pass. This is
    -- what the eye sees, and it lands immediately instead of ~1.1s later.
    -- (No global restore here -> no phantom interact prompt.)
    set_group_vis(OBJECTIVES_MATCH, show_objectives and VIS_VISIBLE or VIS_COLLAPSED)
    set_group_vis(NAVPOINTS_MATCH,  show_navpoints  and VIS_VISIBLE or VIS_COLLAPSED)

    -- Then re-assert the full HUD state. Guarded: if this throws, the latch is
    -- already clear, so the hotkey can't wedge.
    local ok, err = pcall(apply)
    if not ok then log("nav toggle apply error: " .. tostring(err)) end
    save_current()
end

RegisterKeyBind(Key.N, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
    n_group = true
    if not n_pending then n_pending = true; ExecuteWithDelay(60, process_n) end
end)

RegisterKeyBind(Key.N, { ModifierKey.SHIFT }, function()
    if not n_pending then n_pending = true; ExecuteWithDelay(60, process_n) end
end)

-- Shift+C: toggle the crosshair (reticle) on/off.
RegisterKeyBind(Key.C, { ModifierKey.SHIFT }, function()
    hide_crosshair = not hide_crosshair
    enabled = true
    if not hide_crosshair then set_group_vis("reticle", VIS_VISIBLE) end
    apply()
    log((hide_crosshair and "CROSSHAIR OFF" or "CROSSHAIR ON") .. " - Shift+C to toggle.")
    save_current()
end)

-- HUD SCALE live adjust:
--   Ctrl+Shift+[-]  smaller   Ctrl+Shift+[=]  bigger   Ctrl+Shift+K  reset
-- (numpad - / + also work). The physical "-" and "=" keys are OEM_MINUS / OEM_PLUS.
local function set_hud_scale(v)
    if v < HUD_SCALE_MIN then v = HUD_SCALE_MIN end
    if v > HUD_SCALE_MAX then v = HUD_SCALE_MAX end
    HUD_SCALE = v
    pcall(apply_hud_scale)   -- apply immediately, don't wait for the enforce tick
    log(string.format("HUD SCALE: %.2fx  ( Ctrl+Shift+[-] smaller / Ctrl+Shift+[=] bigger / Ctrl+Shift+K reset )", HUD_SCALE))
    save_current()
end
-- Guarded so an unknown Key enum name can't break the mod load; register both the
-- main-keyboard OEM keys and the numpad keys so at least one set works.
local function bind_scale(key, delta)
    if not key then return end
    pcall(function()
        RegisterKeyBind(key, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
            set_hud_scale(HUD_SCALE + delta)
        end)
    end)
end
bind_scale(Key.OEM_MINUS, -HUD_SCALE_STEP)   -- main-keyboard "-"
bind_scale(Key.OEM_PLUS,   HUD_SCALE_STEP)   -- main-keyboard "=" (i.e. "+")
bind_scale(Key.SUBTRACT,  -HUD_SCALE_STEP)   -- numpad "-"
bind_scale(Key.ADD,        HUD_SCALE_STEP)   -- numpad "+"
pcall(function()
    RegisterKeyBind(Key.K, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function()
        set_hud_scale(1.0)
    end)
end)

-- CE-LAYOUT POSITION HOTKEYS (a real feature, not a debug tool): the right
-- offsets depend on each user's HUD scale and aspect ratio, so they position
-- the cradles by eye and the values persist to settings.ini.
--   Ctrl+Shift+Arrows : nudge the ammo/weapon cradle, 25 units per press
--   Ctrl+Alt+Arrows   : nudge the grenade+equipment group
if CE_LAYOUT then
    local ammo_group = { TRANSLATE["weaponcradle"] }
    local gren_group = { TRANSLATE["grenadecradle"], TRANSLATE["equipmenticon"] }

    local function ce_nudge(group, label, dx, dy)
        for _, t in ipairs(group) do t.x = t.x + dx; t.y = t.y + dy end
        -- Keep the launch constants in sync. ce_grenades_right() re-applies
        -- CE_GREN_* every time it reparents, which happens again on each HUD
        -- rebuild (level change) -- without this, a session's grenade tuning
        -- gets saved to the ini and then snapped back to the launch value on
        -- the next level load. Ammo is unaffected: nothing re-applies it.
        if label == "grenades" then
            CE_GREN_X, CE_GREN_Y = group[1].x, group[1].y
        end
        pcall(apply_translates)
        log(string.format("CE TUNE %s -> x=%d  y=%d", label, group[1].x, group[1].y))
        save_current()   -- tuned position survives restarts
    end

    -- Guard + count, so a renamed Key enum in a future UE4SS can't silently
    -- delete the position hotkeys (the pcall alone would swallow it).
    local bound = 0
    local function bind_nudge(key, mods, group, label, dx, dy)
        if not key then return end
        local ok = pcall(function()
            RegisterKeyBind(key, mods, function() ce_nudge(group, label, dx, dy) end)
        end)
        if ok then bound = bound + 1 end
    end

    local CS = { ModifierKey.CONTROL, ModifierKey.SHIFT }
    local CA = { ModifierKey.CONTROL, ModifierKey.ALT }
    bind_nudge(Key.LEFT_ARROW,  CS, ammo_group, "ammo",     -25,   0)
    bind_nudge(Key.RIGHT_ARROW, CS, ammo_group, "ammo",      25,   0)
    bind_nudge(Key.UP_ARROW,    CS, ammo_group, "ammo",       0, -25)
    bind_nudge(Key.DOWN_ARROW,  CS, ammo_group, "ammo",       0,  25)
    bind_nudge(Key.LEFT_ARROW,  CA, gren_group, "grenades", -25,   0)
    bind_nudge(Key.RIGHT_ARROW, CA, gren_group, "grenades",  25,   0)
    bind_nudge(Key.UP_ARROW,    CA, gren_group, "grenades",   0, -25)
    bind_nudge(Key.DOWN_ARROW,  CA, gren_group, "grenades",   0,  25)
    if bound == 8 then
        log("CE position hotkeys ready (8/8): Ctrl+Shift+Arrows = ammo, Ctrl+Alt+Arrows = grenades")
    else
        log("WARNING: only " .. bound .. "/8 CE position hotkeys registered - arrow-key tuning is degraded")
    end
end

RegisterKeyBind(KEY_DUMP,   function() dump_widgets() end)
RegisterKeyBind(KEY_REPORT, function() layout_report() end)
RegisterKeyBind(KEY_TREE,   function() tree_dump() end)

-- F8: dump every number/text widget with its class, name, current text,
-- and how OG-ammo classifies it. Hold the weapon in question, press F8.
RegisterKeyBind(KEY_AMMODUMP, function()
    log("---- ammo / text widgets (name | text | vis | tag) ----")
    for _, t in ipairs(ammo_pool()) do
        if t:IsValid() then
            local nm  = short_name(t)
            local low = nm:lower()
            local txt = widget_text(t) or ""
            local tag = ""
            if is_reserve_name(low)  then tag = "RESERVE(keep)"
            elseif is_mag_name(low)   then tag = "MAG(hide)"
            elseif is_slash(t, low)   then tag = "SLASH(hide)"
            elseif is_percent(t, low) then tag = "PERCENT(charge)" end
            local vis = is_shown(t) and "SHOWN" or "hidden"
            -- only print the interesting ones (tagged, ammo-named, or short text)
            if tag ~= "" or string.find(low, "ammo", 1, true) or #txt <= 4 then
                log(nm .. " | '" .. txt .. "' | " .. vis .. " | " .. tag)
            end
        end
    end
    -- STRUCTURAL widgets: the charge/cooldown bar and the per-weapon scope
    -- reticles. These differ by weapon HARDWARE, not text, so their visibility
    -- may separate charge weapons from ballistic where the text widgets can't.
    log("---- weapon structure widgets (class | count-shown/total) ----")
    local struct = {
        "WBP_WeaponCooldownBar_C",
        "WBP_WeaponAim_Scope_BeamRifle_C", "WBP_WeaponAim_Scope_Plasma_C",
        "WBP_WeaponAim_Scope_Needler_C",   "WBP_WeaponAim_Scope_Sniper_C",
        "WBP_WeaponAim_Scope_Shared_C",
    }
    for _, cls in ipairs(struct) do
        local objs = FindAllOf(cls)
        local shown, total = 0, 0
        if objs then
            for _, w in ipairs(objs) do
                if w:IsValid() then
                    total = total + 1
                    if is_shown(w) then shown = shown + 1 end
                end
            end
        end
        log(cls .. " | " .. shown .. " shown / " .. total .. " total")
    end
    -- CINEMATIC / TITLE widgets: catch whatever draws chapter-title cards and the
    -- letterbox bars. Press F8 WHILE a chapter card is on screen. Prints any live
    -- widget whose class matches these keywords, with its visibility.
    log("---- cinematic / title widgets (class | vis) ----")
    local words = { "banner", "countdown", "subtitle", "cinematic", "letterbox",
                    "transmission", "title", "chapter", "cutscene" }
    local allw = FindAllOf("UserWidget")
    if allw then
        local seen = {}
        for _, w in ipairs(allw) do
            if w:IsValid() then
                local cn = class_name(w)
                if cn then
                    local lc = cn:lower()
                    for _, kw in ipairs(words) do
                        if string.find(lc, kw, 1, true) then
                            local short = cn:match("([^%.]+)$") or cn
                            local key = short .. (is_shown(w) and "|1" or "|0")
                            if not seen[key] then
                                seen[key] = true
                                log(short .. " | " .. (is_shown(w) and "SHOWN" or "hidden"))
                            end
                            break
                        end
                    end
                end
            end
        end
    end
    -- GRENADE-SWAP KEYBIND: the little key-glyph that flashes when you cycle
    -- grenade types. SWAP GRENADES, then immediately press F8 to catch it SHOWN.
    -- Prints any keybind/glyph/input-named widget so we can hide just that child.
    log("---- keybind / glyph widgets (class | vis) ----")
    local kwords = { "keybind", "glyph", "button", "input", "bind", "prompt",
                     "hint", "swap", "action", "grenade" }
    local kw_all = FindAllOf("UserWidget")
    if kw_all then
        local seen = {}
        for _, w in ipairs(kw_all) do
            if w:IsValid() then
                local cn = class_name(w)
                if cn then
                    local lc = cn:lower()
                    for _, kw in ipairs(kwords) do
                        if string.find(lc, kw, 1, true) then
                            local short = cn:match("([^%.]+)$") or cn
                            local key = short .. (is_shown(w) and "|1" or "|0")
                            if not seen[key] then
                                seen[key] = true
                                log(short .. " | " .. (is_shown(w) and "SHOWN" or "hidden"))
                            end
                            break
                        end
                    end
                end
            end
        end
    end
    log("---- end ----")
end)

--------------------------------------------------------------------
--  PERSISTENCE
--------------------------------------------------------------------

NotifyOnNewObject("/Script/UMG.UserWidget", function(widget)
    if not enabled then return end
    local name = class_name(widget)
    if not name then return end
    local lname = name:lower()
    -- A reticle just spawned: drop the instance cache so the ammo classifier
    -- sees it on its very next pass. Otherwise the empty lists cached during
    -- HUD warm-up would linger until the ~2s periodic clear, extending the
    -- window where the magazine number is still on screen after a load.
    if string.find(lname, "wbp_weaponaim_scope", 1, true) then
        clear_reticle_cache()
    end
    if is_hud(name) then
        if (not matches_any(lname, LEAVE_TO_GAME))
           and (not matches_any(lname, NEVER_TOUCH))
           and (not matches_any(lname, current_keep())) then
            ExecuteWithDelay(50, function() set_vis(widget, VIS_COLLAPSED) end)
        end
    elseif matches_any(lname, EXTRA_HIDE)
            or ((not KEEP_VISOR_LINES) and matches_any(lname, VISOR_EXTRA)) then
        ExecuteWithDelay(50, function() set_vis(widget, VIS_COLLAPSED) end)
    end
    -- catch a rebuilt cradle button-prompt glyph the instant it appears
    if is_cradle_prompt(name, widget) then
        ExecuteWithDelay(50, function() set_vis(widget, VIS_COLLAPSED) end)
    end
end)

LoopAsync(ENFORCE_INTERVAL_MS, function()
    if enabled then
        -- Each step guarded SEPARATELY so one failing can't skip the others.
        local ok1, e1 = pcall(apply)
        if not ok1 then log("apply error: " .. tostring(e1)) end
        local ok2, e2 = pcall(apply_moves)
        if not ok2 then log("moves error: " .. tostring(e2)) end
        local ok3, e3 = pcall(apply_translates)
        if not ok3 then log("translate error: " .. tostring(e3)) end
        local ok4, e4 = pcall(apply_hud_scale)
        if not ok4 then log("hud-scale error: " .. tostring(e4)) end
    end
    return false
end)

-- Dedicated fast loop for the ammo trim so weapon swaps snap instantly instead
-- of waiting up to a full second. It's a light, visibility-only pass, so running
-- it often is cheap and does not flicker.
if OG_AMMO then
    LoopAsync(16, function()
        if enabled then
            local ok, e = pcall(apply_og_ammo)
            if not ok then log("og-ammo(fast) error: " .. tostring(e)) end
        end
        return false
    end)
end

-- Dedicated fast sweep for cradle button-prompt glyphs (the grenade-swap "1",
-- the equipment "G", etc.). The main enforce loop only runs every second and
-- NotifyOnNewObject only fires on first construction, so a re-shown glyph can
-- flash for up to a full second on a weapon/grenade swap. This catches it within
-- ~120ms. Visibility-only and parent-filtered (HIDE_ACTIONWIDGET_UNDER), so it
-- never touches interact-prompt button icons.
-- PERF: the full scan + per-widget Outer-chain walk now runs only every ~500ms;
-- the per-tick work is just re-collapsing the KNOWN glyphs (cheap IsValid +
-- SetVisibility). A re-shown glyph is the same object, so it's already in the
-- cache and still gets caught within one frame -- which is the entire point of
-- this loop. A brand-new instance waits for the next rescan at worst, and
-- NotifyOnNewObject usually collapses it after 50ms anyway.
local cradle_cache = {}
local cradle_tick = 0
local CRADLE_RESCAN_TICKS = 31   -- ~500ms at the 16ms loop rate

local function hide_cradle_prompts()
    cradle_tick = cradle_tick + 1
    if (cradle_tick % CRADLE_RESCAN_TICKS) == 1 then
        cradle_cache = {}
        local acts = FindAllOf("WBP_MetUI_ActionWidget_C")
        if acts then
            for _, w in ipairs(acts) do
                if w:IsValid() and is_cradle_prompt(class_name(w), w) then
                    cradle_cache[#cradle_cache + 1] = w
                end
            end
        end
    end
    for _, w in ipairs(cradle_cache) do
        if w:IsValid() then set_vis(w, VIS_COLLAPSED) end
    end
end
-- 16ms ~= one frame at 60fps: the glyph is collapsed before your eye can
-- resolve it. Faster than this is wasted work -- the display can't paint it
-- sooner than it refreshes.
LoopAsync(16, function()
    if enabled then
        local ok, e = pcall(hide_cradle_prompts)
        if not ok then log("cradle-prompt(fast) error: " .. tostring(e)) end
    end
    return false
end)

-- "Remove the repaint": HIJACK the game's own color setter (CONFIRMED WORKING).
-- When the game sets a reserve text block's color (dim, on each ammo change), we
-- overwrite the incoming value with our bright cyan *before* the call runs. The
-- game then paints bright itself, so the dim value never hits the screen -> no
-- race, no flicker. This is what makes the bright reserve possible without an
-- asset edit. (If a future patch sets the color a non-UFunction way, this stops
-- firing and the reserve simply reverts to its faded default -- no breakage.)
if OG_AMMO and RESERVE_HIJACK then
    local ok, err = pcall(function()
        RegisterHook("/Script/UMG.TextBlock:SetColorAndOpacity", function(self, InColor)
            if not enabled then return end
            local okc = pcall(function()
                local w = self:get()
                if not (w and w:IsValid()) then return end
                local nm = short_name(w):lower()
                if is_reserve_name(nm) then
                    -- reserve number: force our bright cyan
                    local c = InColor:get()
                    c.SpecifiedColor.R = RESERVE_COLOR.R
                    c.SpecifiedColor.G = RESERVE_COLOR.G
                    c.SpecifiedColor.B = RESERVE_COLOR.B
                    c.SpecifiedColor.A = RESERVE_COLOR.A
                    c.ColorUseRule = 0
                elseif (not last_charge_up) and is_mag_name(nm) then
                    -- ballistic magazine number: force fully transparent the instant
                    -- the game paints it, so it never flashes on a weapon swap before
                    -- the 16ms collapse sweep catches it. (Skipped for charge weapons,
                    -- whose mag field holds the visible "NN%".)
                    local c = InColor:get()
                    c.SpecifiedColor.A = 0.0
                    c.ColorUseRule = 0
                end
            end)
            if not okc then end
        end)
    end)
    if ok then log("reserve HIJACK hook active on TextBlock:SetColorAndOpacity")
    else log("reserve HIJACK hook failed to register: " .. tostring(err)) end
end

-- NOTE: stopping the cradle's animations (via a low-freq PlayAnimation hook, which
-- was itself STABLE -- no crash) did soften the mag flash, but StopAllAnimations is
-- all-or-nothing: it also froze the reserve number's fade-in and left it dim. No way
-- to target just the equip animation without its name. Not worth breaking the bright
-- reserve to soften one frame.

-- NOTE (hard-won conclusion): the mag flash CANNOT be killed from Lua. Every hook
-- that would force the number hidden at the source crashes or breaks something:
--   * SetVisibility param override -> access-violation crash (hot base function).
--   * SetText re-call (post hook)  -> re-entrancy crash.
--   * SetText arg rewrite (pre hook, InText:set) -> access-violation crash in the
--     hook dispatch. Setting/replacing a param VALUE is unsafe here.
-- The ONLY safe hijack is MUTATING STRUCT FIELDS of a param in place -- which is
-- what the reserve/mag SetColorAndOpacity hook does (c.SpecifiedColor.A = 0). But
-- the game doesn't call SetColorAndOpacity on the flash frame, so it can't cover
-- it. Net: the rare ~1-frame mag flash on animated-cradle weapons is the floor for
-- a runtime mod; only an asset edit (pull the number from the equip animation) can
-- remove it. Left hidden via collapse + render-opacity + the color alpha-zero.
--
-- NOTE: a SetVisibility hijack that forced the mag Collapsed at the source DID kill
-- the flash completely -- but hooking /Script/UMG.Widget:SetVisibility and
-- overriding its argument mid-call crashed the game within seconds, every time,
-- even with an IsValid guard and a purely integer-keyed (no-string) callback. The
-- crash is the parameter override on that hot function, not something a guard can
-- fix. Confirmed twice. SetVisibility hooking is untenable here. The mag is hidden
-- via collapse + render-opacity + the SetColorAndOpacity alpha-zero, which is
-- stable; a rare ~1-frame flash on the animated-cradle weapons is the trade-off.

-- TEMP DIAGNOSTIC: reserve ammo vanishing ~5-10s after load. Samples every
-- ammo text widget twice a second and logs ONLY when the STATE signature
-- changes (text is shown but excluded from the signature, so firing doesn't
-- spam). The log therefore brackets the exact moment the reserve disappears
-- and names which property moved: collapsed (vis), faded (op), or destroyed.
local AMMO_WATCH = true
if AMMO_WATCH then
    local last_sig
    LoopAsync(500, function()
        if enabled then
            pcall(function()
                local sig, out = {}, {}
                for _, t in ipairs(ammo_pool()) do
                    if t:IsValid() then
                        local nm = short_name(t)
                        local n  = nm:lower()
                        if is_mag_name(n) or is_reserve_name(n) or is_slash(t, n)
                           or string.find(n, "ammo", 1, true) then
                            local vis, op = -1, -1
                            pcall(function() vis = t:GetVisibility() end)
                            pcall(function() op  = t:GetRenderOpacity() end)
                            local shown = tostring(is_shown(t))
                            sig[#sig + 1] = string.format("%s:%d:%.2f:%s", nm, vis, op, shown)
                            out[#out + 1] = string.format("%s['%s' vis=%d op=%.2f shown=%s]",
                                nm, widget_text(t) or "", vis, op, shown)
                        end
                    end
                end
                local s = table.concat(sig, "|")
                if s ~= last_sig then
                    last_sig = s
                    log("AMMOWATCH " .. (#out > 0 and table.concat(out, "  ") or "(no ammo widgets)"))
                end
            end)
        end
        return false
    end)
end

log("Loaded  [BUILD v2.1]  Settings persisted to settings.ini.")
log(string.format("  visor=%s  scale=%.2f  crosshair_only=%s  hide_crosshair=%s  objectives=%s  navpoints=%s  ce_layout=%s",
    tostring(KEEP_VISOR_LINES), HUD_SCALE, tostring(crosshair_only), tostring(hide_crosshair),
    tostring(show_objectives), tostring(show_navpoints), tostring(CE_LAYOUT)))
log("Ctrl+Shift+H=crosshair-only, Ctrl+Shift+V=visor lines.")
log("HUD SCALE: Ctrl+Shift+- =smaller, Ctrl+Shift++ =bigger, Ctrl+Shift+K=reset (numpad +/- too).")
log("Ctrl+Shift+N=objectives+waypoints, Shift+N=waypoints only, Shift+C=crosshair.")
if CE_LAYOUT then
    log("CE layout ON: Ctrl+Shift+Arrows move the ammo cradle, Ctrl+Alt+Arrows move grenades (saved).")
end
log("Diagnostics: F9=dump, F7=keeper report, F6=tree dump.")

