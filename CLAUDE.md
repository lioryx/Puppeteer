# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Puppeteer (formerly HealersMate) is a **World of Warcraft Vanilla 1.12 addon** — a healer-oriented unit frames replacement (alternative to VuhDo/Cell/Healbot). It runs inside the WoW client's embedded Lua 5.0 interpreter; there is **no build, compile, lint, or automated test step**. You cannot run the code outside the game.

- `## Interface: 11200` in `Puppeteer.toc` pins it to the 1.12 client (primarily targeting Turtle WoW).
- Development loop: edit `.lua`/`.xml`, copy into the client's `Interface/AddOns/Puppeteer` folder, then `/reload` in-game (or relaunch). Errors surface in-game; install an error addon (e.g. BugSack/!ImprovedErrorFrame) to read them.
- In-game commands for manual testing: `/pt help`, `/pt reset` (reset frame positions), `/pt check` (re-evaluate group/roster), `/pt update` (re-apply profiles & redraw), `/pt testui` (show frames with fake data, no group needed), `/pt toggle|show|hide`, `/pt roles`. `/puppeteer` and `/hm` are aliases.

## Load order matters

Files are loaded by the game in the exact order listed in `Puppeteer.toc`. There are no `require`/`import` statements — everything shares globals. If file B uses something file A defines at load time, A must appear above B in the `.toc`. When adding a new file, **you must add it to `Puppeteer.toc`** in the right position or it won't load.

Rough load sequence: Ace2 + bundled libs → locales → custom GUI lib (`libs/gui/`) → `Puppeteer.lua` (root namespace) → `core/` modules → settings/profiles/unit-frame classes → `gui/` settings UI → remaining `libs/` (`PTUnit`, `AuraTracker`, `HealPredict`, etc.).

## The environment / namespacing pattern (most important convention)

This codebase does **not** use `local` for most module members. Instead, nearly every file begins with:

```lua
PTUtil.SetEnvironment(SomeTable)   -- e.g. Puppeteer, PTUnit, PTGuiLib
local _G = getfenv(0)
```

`PTUtil.SetEnvironment` (in `libs/Util.lua`) calls `setfenv` so that **bare global assignments and `function Foo()` definitions in that file land as fields on `SomeTable`**, with `__index` fallback to `PTUnitProxy` (if SuperWoW present) then real `_G`. Consequences:

- In a file with `SetEnvironment(Puppeteer)`, writing `function CheckGroup()` actually defines `Puppeteer.CheckGroup`. Reading `RaidUnits` resolves through the metatable chain.
- To touch the **true** global table (SavedVariables like `PTOptions`, Blizzard frames, `_G.this`), use the file-local `_G` captured right after `SetEnvironment`.
- Many files re-open the same `Puppeteer` table (`Puppeteer.lua`, `core/Bindings.lua`, `core/ActionBindings.lua`, `core/EventHandler.lua`, …) — they are partial definitions of one big namespace, not separate modules.

Key namespaces: `Puppeteer` (root logic), `PTUtil` (pure helpers, no side effects), `PTUnit` (per-unit data cache), `PTUnitProxy` (SuperWoW-only custom-unit proxy), `PTGuiLib`/`PTGuiLib` components, `PuppeteerSettings`, `PTProfileManager`, `PTGuidRoster`, `PTHealPredict`, `PTAuraTracker`.

## Optional client mods drive most branching

`libs/Util.lua` detects optional client-side mods at load and exposes feature levels: **SuperWoW**, **Nampower**, **UnitXP SP3**, **VanillaUtils**. A huge amount of logic forks on `util.IsSuperWowPresent()`:

- **Without SuperWoW**: units are tracked by unit ID (`party1`, `raid7`, …); `PTUnit.Cached` is keyed by unit ID; only ~28yd range checks; no Focus/Enemy frames; no aura timers.
- **With SuperWoW**: tracking is **GUID-based**; `PTUnit.Cached` keyed by GUID; `PTGuidRoster` maps GUID↔units; custom unit types ("focus", "enemy") become available via `PTUnitProxy`; accurate distance, line-of-sight, and buff/HoT durations.

When changing unit/aura/heal logic, check **both** code paths. The `UnitFrames(unit)` iterator in `Puppeteer.lua` even has two implementations chosen at init (`OpenUnitFramesIterator`).

## Core data model

- **`PTUnit` (`libs/PTUnit.lua`)** — cached, readable snapshot of a unit: buffs/debuffs (arrays + name maps + typed-debuff sets), aura timers (SuperWoW), distance, sight, PvP display state, healing modifiers. `PTUnit.Get(unitOrGuid)` / `PTUnit.Cached`.
- **`PTUnitFrame` (`PTUnitFrame.lua`)** — one on-screen frame for a unit (health/power bars, incoming heal, marks, aggro outline, auras, range/sight). Methods like `:UpdateAll`, `:UpdateAuras`, `:UpdateIncomingHealing`, `:UpdateOutline`, `:UpdateRange`.
- **`PTUnitFrameGroup` (`PTUnitFrameGroup.lua`)** — a layout container of frames with show conditions and role sorting. Groups created in `initUnitFrames` (`Puppeteer.lua`): **Party, Pets, Raid, Raid Pets, Target**, plus **Focus, Enemy** when SuperWoW is present. `AllUnitFrames` (flat array) and `PTUnitFrames[unit]` (unit→frames) index them.
- **`CheckGroup()` (`Puppeteer.lua`)** is the central "rescan everything" routine: refreshes roster, decides which frames show, and updates range/auras/heals/outline. `CheckGroupThrottled()` token-buckets rapid calls.

## Bindings system

Click/wheel/key → action, the addon's headline feature. `core/Bindings.lua` (data, loadouts, lookup), `core/ActionBindings.lua` (built-in non-spell actions: Target, Assist, Follow, Menu, Role, Focus…), `core/OverrideBindings.lua` (mouse-wheel & key capture; `Bindings.xml` routes WoW key bindings into `Puppeteer.HandleKeyPress(n)`). A binding has `{Type = "SPELL"|"ITEM"|"MACRO"|"ACTION"|"SCRIPT"|"MENU", Data = ...}`. Bindings are organized into **loadouts**, split by **Friendly/Hostile** target, then by modifier (Shift/Ctrl/Alt combos) and button. Entry point on click: `UnitFrame_OnClick` → `GetBindingFor` → `RunBinding`.

## Settings, profiles, persistence

- SavedVariables (declared in `.toc`): **global** = `PTGlobalOptions`, `PTHealCache`, `PTPlayerHealCache`, `PTRoleCache`; **per-character** = `PTBindings`, `PTOptions`.
- `PuppeteerSettings.lua` defines option defaults (`SetDefaults`) and tracked-debuff config. `Profile.lua` / `ProfileManager.lua` manage frame-appearance profiles assigned per group. The settings UI lives in `gui/` (built on the custom `PTGuiLib`).
- `OnAddonLoaded` (`Puppeteer.lua`) is the master init: defaults, default bindings, mod setup, role cache, profiles, heal-predict hookup, then `initUnitFrames()` + `StartUnitTracker()`. User-editable **OnLoad/OnPostLoad Lua scripts** are `loadstring`-run here inside `pcall`.

## Custom GUI library

`libs/gui/` is a bespoke, Puppeteer-specific widget toolkit (not Ace GUI). `PTGuiLib.Get("component_type", parent)` acquires from a recycle pool; components self-register via `RegisterComponent`. Component classes live in `libs/gui/component/`; higher-level Puppeteer widgets in `gui/`.

## Heal prediction & rosters

- `libs/HealPredict.lua` (`PTHealPredict`) + bundled `libs/ace/HealComm-1.0` provide incoming-heal numbers. With SuperWoW, predictions are GUID-accurate and pushed via `PTHealPredict.HookUpdates`; without it, falls back to HealComm events + RosterLib. **HealComm version mismatches with other addons corrupt raid-wide predictions** — the code warns about this on load.
- `libs/GuidRoster.lua` (`PTGuidRoster`, SuperWoW only) maintains GUID↔unit maps that the iterator and caches depend on.

## Localization

`locale/Locale.lua` plus `enUS`/`esES`/`ptBR`/`deDE`/`ruRU`/`zhCN`. User-facing strings should go through the locale system rather than being hardcoded.

## Gotchas specific to Vanilla Lua 5.0 / WoW 1.12

- No `#tbl` length operator — use `table.getn` / `table.setn`. No `string.match`/`gmatch` in the modern sense; use `string.find`/`gfind`/`string.gsub`. No `select`, no integer/`//`.
- Frame `OnClick`/`OnUpdate` handlers read the implicit global `this` (and `arg1`, etc.) — that's why code saves/restores `_G.this`.
- `Compost-2.0` is used for table recycling (`compost`/`CompostReclaim`); reused tables must be cleared, not reallocated, in hot paths.
- The codebase ships many `print(...)` debug calls; `Puppeteer.print` is gated on `PTOptions.Debug` and routes to a chat window literally named "Debug".
