# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Running the App

```bash
love .        # Run from the project root directory
```

LÖVE2D must be installed. No build step, no external dependencies — pure Lua + LÖVE2D standard library. Base window is 320×617 (conf.lua), resizable down to 230×230.

## Unit Tests

Tests are registered via `gdsGui_unitTests_registerSuite(name, fn)` and run automatically at load time. The GUI library registers a `"gui"` suite in `unitTests_gdsGuiLib.lua`; the app registers an `"app"` suite at the bottom of `main.lua`. Both suites must be registered before `gdsGui_dev_createUnitTestObjects()` is called (last line of `main.lua`), which builds the on-screen test UI.

To re-run tests at runtime, the dev panel has a re-run button. Test definitions use `gdsGui_dev_testExecute { id, funcName, funcParameters, funcExpctOutput }`.

## Architecture

### Two-layer structure

**Application layer** (`main.lua`, `conf.lua`): The pilot companion app — UTC clock, dual-mode timer (count up/down), altitude/time/degree selectors, crosswind calculator, FPM calculator, alarm system with beep/vibrate.

**GUI framework** (`Libraries/gds_love2d_gui/`): A reusable, self-contained GUI library. `loader_gdsGuiLib.lua` is the entry point that `require`s all modules in dependency order. The library is independent of application logic.

### GUI library modules

All module files follow the naming pattern `<name>_gdsGuiLib.lua`. All public functions are prefixed `gdsGui_`.

| File | Purpose |
|------|---------|
| `general_gdsGuiLib.lua` | `globApp` initialization, DPI/safe-area helpers, resize detection, all touch/mouse routing, `gdsGui_update()`, `gdsGui_draw()` |
| `pages_gdsGuiLib.lua` | Page creation, switching, loading-screen transitions |
| `buttons_gdsGuiLib.lua` | Button creation, state machine (released/pressed/deactivated), drawing |
| `container_gdsGuiLib.lua` | Layout containers (header/footer/body roles), scrollable regions, widget grouping |
| `scrollBar_gdsGuiLib.lua` | Independent and table-linked scrollbars, drag, discrete stepping, sprite support |
| `outputTxtBox_gdsGuiLib.lua` | Read-only text labels with momentum scroll (coasting + bounce) |
| `table_gdsGuiLib.lua` | Sortable/filterable data table with momentum scroll matching outputTxtBox physics |
| `inputTxtBox_gdsGuiLib.lua` | Editable text input fields with validation |
| `rotaryKnobs_gdsGuiLib.lua` | Single and dual (concentric) rotary knobs with detents |
| `haptics_gdsGuiLib.lua` | Haptic feedback abstraction |
| `saveLoad_gdsGuiLib.lua` | Persistent save/load via `love.filesystem` |
| `timeControl_gdsGuiLib.lua` | Time-based event triggers |
| `unitTests_gdsGuiLib.lua` | Test registration, execution, and result display |
| `devSettings_gdsGuiLib.lua` | Dev overlay (FPS, dimensions, page ID), dev panel, 8-tap corner to open |

### Key design patterns

**`globApp` global table** — defined at the bottom of `general_gdsGuiLib.lua`. Holds all shared state: `globApp.objects.{buttons, outputTextBox, scrollBars, rotaryKnobs, tables}`, safe area (`globApp.safeScreenArea.{x,y,w,h,xw,yh}`), OS, orientation, and flags. Every module appends its object list to `globApp.objects` at load time.

**Position/size arguments** — `x` and `y` passed to constructors are fractions (0–1) of the safe screen area, not pixels. They are resolved to pixels via `gdsGui_general_relativePosition(anchorPoint, x, y, width, height, baseX, baseY, baseW, baseH)`. Anchor points are two-character strings: `LT CT RT / LC CC RC / LB CB RB` (Left/Center/Right × Top/Center/Bottom).

**Callbacks by name** — Button and scrollbar callbacks are stored as strings and resolved at call time via `_G[callbackString](...)`. All callback functions must be globals in `main.lua`.

**Draw order** — `gdsGui_general_draw()` draws back-to-front: outputTxtBox → table → scrollBar → rotaryKnob → button. Objects on pages other than the active page are skipped.

**Resize handling** — `gdsGui_general_resizeDetect()` is polled every frame inside `gdsGui_update()`. On change it updates `globApp.safeScreenArea`, then calls `obj:resize()` on every button, table, scrollbar, and rotary knob. outputTxtBox resize is not yet wired (`TODO` in `general_gdsGuiLib.lua`).

**Safe area** — On desktop the safe area equals the full window. On iOS/Android it applies system insets (top 6%, bottom 6% in portrait). The app can simulate an unsafe area by calling `gdsGui_general_simulateUnsafeArea()` instead.

**Pages** — `pages` is a global array. Each page has an integer index and a name string. All widget constructors take a page name; widgets only draw and receive input when their page matches the active page (`globApp.currentPageIndex`).

**Momentum scroll physics** — Both `outputTxtBox` and `table` implement identical spring-damper physics: friction-based coasting, elastic rubber-band resistance past boundaries, and a critically-damped spring snap-back. Constants (friction, omega, rubber-band factor) are local to each module.

**Container system** — Widgets are always placed inside named containers, not directly on pages. Create containers first with `gdsGui_container_create(name, pageName, title, height, padding, role)`, where role is `"pageHeader"`, `"pageFooter"`, or omitted for a scrollable body. Pass the container name as the last argument to widget constructors. After all widgets on a page are defined, call `gdsGui_container_finalise(pageName)` — this triggers layout, sizing, and scroll-state initialization. Skipping this call leaves the page broken.

**Object lookup by name** — Every widget has a unique `.name` string. The API operates on names, not references: `gdsGui_button_setState("myBtn", state)`, `gdsGui_outputTxtBox_setText("myLabel", text)`. Widget names in `main.lua` use a `panelName_widgetRole` convention (e.g. `"timerPanel_resetBtn"`).

**Dirty-flag rendering** — `main.lua` uses sentinel variables (`_prevTimerT`, `_prevAltitude`, etc.) so `gdsGui_outputTxtBox_setText()` is only called when values actually change, avoiding per-frame string allocation.

**Sprite naming** — Button sprites follow the three-state pattern: `button_<name>_pressed.png`, `button_<name>_released.png`, `button_<name>_deactivated.png`, stored in `Sprites/`. Library sprites live in `Libraries/gds_love2d_gui/librarySprites/` with the prefix `gdsLoveGUI_`.

**Persistent settings** — `appSettings` is a global Lua table loaded at startup via `gdsGui_saveLoad_loadFileContents("appSettings.lua")` and written back with `love.filesystem.write("appSettings.lua", table.show(appSettings, "appSettings"))`. `table.show()` (in `saveLoad_gdsGuiLib.lua`) serializes a table to valid Lua source that can be `load()`ed back. Add new settings keys with a `nil`-guard default immediately after load so they survive missing saves.

### LÖVE2D callbacks

All LÖVE callbacks are wired in `general_gdsGuiLib.lua` (touch/mouse/keyboard) and `main.lua` (load/update/draw). `main.lua` calls `gdsGui_update(dt)` and `gdsGui_draw()` to delegate to the library; the library handles all widget input routing internally.
