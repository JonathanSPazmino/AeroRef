# AeroRef — Per-System Monetization Roadmap

Business model: each schematic system type sells separately in the App Store. Users pay to
unlock each type, so each one needs its own unique, attractive animation to justify a
standalone purchase.

**Pricing decision (locked in):**
- Free tier: **OXYGEN system** — the simplest of all systems, chosen specifically for this
  role. Built (see §0) — catalog items, medium file, and signature shimmer/color all in place.
- All other systems (ELECTRICAL, HYDRAULIC, FUEL, BLEED AIR, PRESSURIZATION): paid, purchased
  separately per system (à la carte) — buying one system type unlocks only that type, for any
  current or future aircraft; every other paid system stays locked until bought on its own.
  No bundle/flat-price-for-all option. Exact per-system price TBD — decided when the app is
  ready to ship, not before.

## 0. Build the OXYGEN system (new, free-tier anchor)
- [x] Design its catalog: SOURCE (OXYGEN SOURCE, bottle/generator), PATH (MANIFOLD, reusing the
      existing generated tube-split pattern), GATE (SHUTOFF VALVE, reusing SWITCH sprites), SINK
      (OXYGEN OUTLET — the same generic "user-named sink" treatment ACTUATOR got, via
      `suggestedName`)
- [x] Decide its medium: a pressurized-gas system like BLEED AIR/PRESSURIZATION (DUCT
      connectors, shimmer flow) — registered via `model/media/oxygen.lua`, same shape as
      `hydraulic.lua`/`bleedAir.lua`
- [x] Give it its own signature idle/flow animation (see §2) — own saturated green + shimmer
      speed/band/alpha tuned between BLEED AIR's and PRESSURIZATION's
- [x] Add the new system type to `SCHEMATIC_CATALOG` (listed first) — the systems gallery
      derives its tiles from `SCHEMATIC_CATALOG` directly, so no separate gallery wiring was
      needed. No `SYSTEM_THUMBNAILS` entry yet (needs a dedicated sprite asset) — falls back to
      the gallery's default elements/wires mini-diagram preview until one is made

## 1. Paywall / entitlement architecture
- [x] Decide the free tier — see pricing decision above (OXYGEN free, rest paid separately per
      system — à la carte, no bundle — at a TBD price each)
- [x] Add an `entitlements` table (which systemTypes are unlocked) — persisted like `appSettings`
      (`appSettings.entitlements`, keyed by systemType, OXYGEN never gets a key and reads as
      entitled unconditionally via `_isSystemTypeEntitled`). StoreKit-launch validation still
      TODO — this is the local-flag half only, same placeholder status `schematicUnlocked` already
      had. The paywall's "Simulate Purchase" button is the testing backdoor —
      `unlockSystemTypeForTesting(systemType)` grants only the one systemType the paywall was
      opened for (matches the à la carte pricing decision above; revised from an earlier
      all-paid-systems-at-once version once that decision changed). `_openSchematicPaywall`
      (main.lua) tracks which systemType a given paywall visit is about
      (`_paywallTargetSystemType`), set by both real redirect sites so the paywall's title/body
      name the specific system and Simulate Purchase only unlocks that one
- [x] Gate the systems gallery: a locked tile (`_systemGalleryItems`' `item.locked`/`.lockedLabel`)
      draws dimmed with a padlock + "PREMIUM" via the gallery widget's new `_galleryLock.draw`
      (schematic_gdsGuiLib.lua) — purely cosmetic, same arm's-length relationship `_galleryBadge`
      already has. The real gate is in `schematicSystemGallerySelected`, which redirects to
      `SchematicPaywall` for a locked systemType on either the "not yet created" placeholder tile
      or an already-created system's tile, before ever creating/opening/menu-ing it. No specific
      price shown yet (exact number still TBD at ship time, per the pricing decision above). No
      hero teaser *animation* yet — that's tied to §2's per-system signature animations, still TBD
- [x] Gate schematic creation/editing itself (not just the gallery tap) — removed the old
      whole-feature `schematicUnlocked` paywall check from `navBackToSchematicHome`/
      `navGoToSystemSchematic` entirely (OXYGEN must stay reachable with zero purchases at all,
      per the free-tier decision), and added the same `_isSystemTypeEntitled` check to
      `navGoToSystemSchematic`'s "jump straight back into the live canvas" shortcut (the one other
      path, besides the gallery tap, that can reach `_openSystemIntoCanvas` for an existing
      system) — a system opened while entitled, or opened before entitlements existed, no longer
      stays reachable once its systemType is locked. No deep-link/duplicate mechanism exists in
      this app to worry about beyond that. Still open: `appSettings.entitlements` itself can get
      out of sync with a real purchase once StoreKit exists (see the unchecked bullets below)
- [ ] "Restore Purchases" button, and a launch-time StoreKit sync so a reinstall/new device recognizes
      prior purchases
- [x] Decide bundle pricing (all 5 at a discount) vs. à la carte only — à la carte only, no
      bundle (see pricing decision above); each paid system is its own separate purchase
- [ ] Handle "already have a schematic in a system you no longer own" (refund, family-sharing revoke) —
      read-only fallback vs. hidden

## 2. Per-system "signature animation"
The mechanical pieces exist (flow dashes, shimmer, leak spray/puffs, idle pulse). What's missing is a
distinct *identity* per system, not just functional cues:
- [x] **ELECTRICAL** — define its own idle/hero motion: decided the existing breathing glow pulse
      (`_glow` in schematic_gdsGuiLib.lua) IS the signature, as-is — no traveling-spark/dash motion
      added on top. (Considered: fast marching dashes reusing HYDRAULIC/FUEL's mechanism, discrete
      spark dots, an irregular/flickering pulse — user chose to keep the current smooth breathing
      glow unchanged.)
- [x] **HYDRAULIC** — red/orange dashes + leak spray + idle pulse (built). Confirmed reachable: traced
      `_colorForSource`/`_colorForPoweredNode` (main.lua) and they're medium-agnostic — not a bug.
      The gray came from `_colorForSource`'s own deliberate rule that a source with no PRESSURE
      value entered yet (still `entity.voltage` internally) shows flat gray rather than a guessed
      powered color — same rule ELECTRICAL's sources are subject to, just never hit because every
      electrical demo/seed/test canvas sets a VOLTAGE and nothing analogous seeds HYDRAULIC's
      PRESSURE. Locked in with a new test,
      `colorForPoweredNode_hydraulicPressureReachesPoweredColorTest`, proving the real red-orange
      constant (`model/media/hydraulic.lua`'s `style.powered`) is reached once PRESSURE is set.
      No code change needed. Follow-up not done here: PRESSURE isn't actually enforced as required
      on a HYDRAULIC source (the main.lua comment calling it "Required" is aspirational, unchecked
      anywhere) — worth revisiting under §4's save/validation sweep if a tester hits this again
- [x] **FUEL** — the amber tint already existed (`model/media/fuel.lua`'s `style.powered`), and the
      dash speed/length were already slower/longer than HYDRAULIC's — just not enough of a
      qualitative difference on their own. Leaned into the tank wave-fill per the TODO's own
      suggestion: added a per-medium `wave` override (`model/media/fuel.lua`'s new `wave` table —
      slower speed, fewer cycles, smaller amplitude than the shared default), threaded through a
      new `gdsGui_schematic_setWaveStyle`/`canvas.waveStyle` (schematic_gdsGuiLib.lua), read by
      `_shapePoly.drawLevel`, same optional-override-with-fallback shape `flowStyle` already has
      for the dash/shimmer animation. HYDRAULIC's RESERVOIR is untouched — no `wave` table of its
      own, so it keeps the original shared constants unchanged. FUEL's tank now visibly sloshes
      lazier/flatter (viscous) than a hydraulic reservoir's quicker multi-ripple
- [x] **BLEED AIR** — added a real heat-haze wiggle: `_pipes.strokePieceWavy`
      (`schematic_gdsGuiLib.lua`) samples each shimmer band as a polyline and offsets it
      perpendicular to the duct by a sine wave (amplitude, period, speed all opt-in via the
      flow table's new `wiggleAmp`/`wigglePeriodPx`/`wiggleSpeed`), scaled down per band by the
      same `crossFrac` the band's own width already scales by so the narrow bright core wobbles
      less than the wide faint glow. `model/media/bleedAir.lua`'s `flow` table is the only one
      that sets these three fields — a plain `_pipes.strokePiece` straight stroke otherwise,
      zero behavior change for FUEL/HYDRAULIC's dashes or PRESSURIZATION's own shimmer
- [x] **PRESSURIZATION** — stays smooth (no wiggle — cooled, settled cabin air next to hot
      engine/APU bleed air), and its pacing now actually ties to live cabin-altitude data instead
      of a fixed dial, closing the "just gentler" gap the code comment flagged. Added real numeric
      plumbing for CONTROLLER's `RATE` property (its own `defaultProperties` row, free text until
      now, same as every other system's custom properties): a new
      `gdsGui_schematic_setNumericPropertyKeys`/`canvas.numericPropertyKeys` hook
      (`schematic_gdsGuiLib.lua`) flags a key's property-grid row numeric at both placement and
      edit time, fed from `model/media/pressurization.lua`'s new `numericPropertyKeys = {RATE =
      true}` (`CABIN ALT` stays plain free text — it's a setpoint, not a tempo, and nothing reads
      it back). `main.lua`'s new `_pressurizationControllerRateFPM` scans the canvas for a numeric
      `RATE` value; `_refreshPressurizationFlowPace` (gated on `systemType == "PRESSURIZATION"`,
      same explicit-check pattern `schematicRefreshGlow` uses for ELECTRICAL) maps `|RATE|` up to
      2000fpm onto the shimmer's `speedPxPerSec` (16 px/s idle/no-CONTROLLER up to 40 px/s at a
      brisk climb/descent) and overwrites `canvas.flowStyle` with it — called once when the system
      opens and again from `schematicCanvasChanged()`, so typing a new RATE re-paces the shimmer
      immediately, not just on next open. Locked in with
      `pressurizationControllerRateFPM_readsNumericRatePropertyTest` and
      `..._blankOrMissingReturnsNilTest`
- [ ] Per system: a short looping "hero" preview (2-4s) usable both as the in-app locked-tile teaser and as
      App Store marketing material
- [x] Settle on a consistent visual language across the 5 (color, motion style, leak behavior) so they read
      as a family of products, not unrelated reskins — audited all three axes across all 6 media files
      (`model/media/*.lua`):
      - **Color**: already fully consistent — every medium shares the identical
        `unpowered = {0.55,0.55,0.55,1}` gray (the one anchor that reads as "one app's design system"),
        each medium's own `powered` hue is unique across all 6 (yellow/red-orange/amber/light-blue/
        pale-green-cyan/saturated-green, no collisions), and `magnitudeLabel`/`magnitudeUnit` follow one
        shared VOLTAGE-or-PRESSURE/V-or-PSI convention. No change needed.
      - **Motion style**: already a coherent, physically-grounded split, not arbitrary per-system
        tuning — liquid media (HYDRAULIC/FUEL) march dashes, gas media (BLEED AIR/PRESSURIZATION/OXYGEN)
        sweep a soft shimmer, ELECTRICAL breathes a glow pulse — tied to what each medium actually IS
        (droplets vs. compressible gas vs. current), not a style pick per system. IDLE PULSE (a liquid
        pipe holding pressurized fluid but not moving) is deliberately liquid-only too
        (`_pipes.drawAllFlow`'s own comment: "a gas duct has no such in-between state... looksPowered is
        binary") — confirmed intentional, not a gap: a gas DUCT's powered/unpowered split has no
        third "holding still" state the way a liquid's fluidPercent/fluidMoving pair does.
      - **Leak behavior**: found and fixed a real inconsistency here. `_pipes.drawOpenPortLeaks`
        (schematic_gdsGuiLib.lua) — a source/manifold's own disconnected port spraying/puffing, as
        opposed to `_pipes.drawLeak`'s wire-dead-end case — was gated `if not _pipes.isLiquid(canvas)...
        then return end`, categorically excluding every gas DUCT system, while `_pipes.hasFlow`'s own
        header comment already establishes the house rule that only the genuinely liquid-specific passes
        (drained-pipe visual) should ever gate on `isLiquid` outright — every other flow/leak pass is
        meant to dispatch BY medium, not exclude one. Changed the gate to `canvas.mode ~= "control"` only,
        with `isLiquid` now purely picking the renderer (`drawLeakSprayAt` droplets vs. `drawAirPuffsAt`
        puff rings), matching `drawLeak`'s own existing dispatch shape exactly. Updated `hasFlow`'s own
        header comment to state the corrected rule. Verified live (placed a BLEED AIR SOURCE with an
        unwired port in a throwaway test aircraft, switched to control mode): no visible change today —
        traced why and confirmed it's expected, not a bug in the fix: no "source" catalog item in ANY
        system (liquid included) authors an explicit `terminals` array, and the MANIFOLD "path" branch's
        own wetness check (`pathElementIsWet`'s `w.fluidMoving`) is liquid-only (model/fluid.lua never
        runs for gas), so neither branch is reachable by today's catalog for gas regardless of this fix.
        The fix is still correct and worth keeping — it removes an unjustified categorical exclusion and
        future-proofs the day a gas catalog item gets explicit terminals (or `pathElementIsWet` is
        ever generalized), rather than needing this same discovery repeated later. Test aircraft/data
        used for the live check was deleted afterward — no save-file residue

## 3. In-App Purchase / App Store technical setup
- [x] Feasibility investigated — see Appendix below. **Verdict: feasible.**
- [ ] Pick StoreKit 1 (Objective-C++, fits existing `ios.mm` pattern, no new language) vs. StoreKit 2
      (Swift, nicer API, needs a bridging header)
- [ ] Link `StoreKit.framework` in `love.xcodeproj`
- [ ] Add native purchase/restore/query functions (`ios.mm` + a small Lua-facing wrap, mirroring the
      existing `vibrate()`/`getSafeArea()` pattern)
- [ ] Create 5 non-consumable In-App Purchase products in App Store Connect, one per paid system
      (no bundle product — à la carte only, per the pricing decision above)
- [ ] Sandbox-test purchase, restore, and failure/cancel flows on-device before anything else here matters
- [ ] Receipt validation: on-device/local-flag is fine for this scale — make the call explicitly
- [x] Price tier decision — separate per-system price, à la carte, no bundle (OXYGEN free); exact
      numbers TBD at ship time

## 4. Functional polish / known gaps
- [x] Fix the fluid-vanishing bug in `model/fluid.lua`'s `step()` (a self-looping pipe run drains its
      source with no credited receiver) — fixed; verified live (reservoir held steady at 27%/102L for
      60s of idle simulation, vs. continuous drain before the fix)
- [x] Verify the ELECTRICAL "powered" color actually triggers in normal use (inference/prediction path) —
      traced the real write path end to end: a typed VOLTAGE genuinely reaches `entity.voltage` through
      the PROPERTIES-edit grid's own SAVE handler (`gdsGui_schematic_internal_onPropertiesSaved`,
      schematic_gdsGuiLib.lua — the same generic `entity[row.key] = tonumber(row.value)` write the
      placement grid's `_applyPlacementExtraRows` also uses), and a bus-tie/relay gate with no learned
      position yet withholds power rather than guessing (model/solver.lua's own documented safe default) —
      correct, not a gap. The existing `colorForPoweredNode_*` tests all hand-injected `entity.voltage`
      into a bare fixture rather than exercising that real write path in one shot — closed with
      `schematicPropertiesSavedVoltageReachesPoweredColorTest` (main.lua), which drives the real SAVE
      function then chains into the same `buildGraph -> solve -> solveSourceAttribution` path
      `schematicVoltageTieBreakIntegrationTest` already uses
- [x] Sweep each system's catalog for the same "generic sink, user-named" treatment ACTUATOR got, where
      it makes sense (e.g. does ELECTRICAL need a generic LOAD beyond LIGHT/MOTOR/HEATER?) — ELECTRICAL
      needs no catalog change: a load's NAME is already free text pre-filled by whichever of
      LIGHT/MOTOR/HEATER was tapped (`_openLoadPropertiesGrid`), and a BUS's own green "+" row reaches the
      identical ADD LOAD flow with no catalog item at all, already fully generic. The real gap the sweep
      found was BLEED AIR: the only system with zero "sink"-tagged catalog item at all, already flagged in
      a code comment as "deliberately blank for now, not a bug" (`_openFundamentalsMenu`,
      main.lua) rather than an oversight — gave it its own BLEED AIR OUTLET (componentType "sink",
      suggestedName = "USER#_OUT", same template OXYGEN OUTLET uses), and corrected that now-stale comment
      (ELECTRICAL already has sink-tagged LIGHT/MOTOR/HEATER loads from this same session's earlier §2 work)
- [x] Confirm save/load round-trips cleanly for a schematic in each system after a purchase lapses/returns —
      `appSettings.entitlements` and `schematicStore` are two entirely separate `love.filesystem.write`
      targets (`_saveAppSettings`/`_saveSchematicStore`); nothing in either save path or
      `gdsGui_saveLoad_loadFileContents` reads entitlement state at all, so a locked system's data
      saves/loads byte-for-byte the same as an unlocked one — only the NAVIGATION path to it
      (`schematicSystemGallerySelected`/`navGoToSystemSchematic`) is gated. Locked in with
      `schematicStoreRoundTripsLockedSystemTypeTest` (main.lua): a real disk save/reload round trip (its
      own throwaway save filename, never the real one) of a HYDRAULIC system saved while
      `entitlements.HYDRAULIC == false`, confirming its element data survives intact
- [x] Undo/redo and snapshot behavior sanity-checked per system now that each is a standalone paid feature —
      confirmed by tracing `_openSystemIntoCanvas` (main.lua): every system switch unconditionally calls
      `gdsGui_schematic_clearUndo("mainCanvas")` first (the function's own comment already names the exact
      risk — "a leftover undo snapshot could otherwise splice a DIFFERENT system's elements/wires/controls
      back in") and repopulates `canvas.snapshots` from that system's own saved `sys.snapshots`, so neither
      ever bleeds across a system switch; the "jump straight back into the live canvas" shortcut
      (`navGoToSystemSchematic`) only skips this when `_canvasLoadedSystemId == schematicStore.currentSystemId`
      — the SAME system, never a different one. All of this is systemType-agnostic by construction (one
      shared canvas populate/clear routine, no per-system branches), and entitlement gating only added an
      earlier check in front of it, never touched it. No test added here — the only way to exercise this
      for real touches the single live "mainCanvas" singleton, which this codebase's own existing tests
      already deliberately avoid doing (see `schematicOpenGateShowsUnpoweredColorTest`'s own comment on
      the identical constraint) since a test run mid-session (the dev panel's re-run button) would
      otherwise hijack whatever real schematic the user has open

## 5. Compliance & store readiness
- [ ] Update `terms.txt` / privacy policy to cover payments, restore, and refunds
- [ ] App Store privacy "nutrition label" update (does payment processing collect anything new?)
- [ ] Screenshots + preview video per system for its own App Store listing section (ties to §2's hero animations)
- [ ] Age rating re-check if not already done
- [ ] App Store review notes explaining the unlock model clearly

---

## Appendix: §3 feasibility notes (StoreKit on this LÖVE2D/Xcode build)

**Verdict: feasible, moderate one-time native-iOS effort, no changes to the existing automated
pipeline's assumptions required.**

Findings:
- `~/softDev/love2d_AeroRef` is a full from-source checkout of love2d/love (not a prebuilt player),
  with its own git history, already archived once (`platform/xcode/build/AeroRef.xcarchive` exists).
  This means custom native code additions are realistic, not blocked by a black-box runtime.
- `gds love2d -inject` (in `~/softDev/projects/gdsLinuxDev/love2d/love2d.sh`) is idempotent and
  surgical: it only clones love2d/love if the directory is missing, and all its pbxproj/plist patches
  check for existing markers before writing. Manual edits (linking a new framework, adding source
  files) will **not** be clobbered by future `-inject`/`-bundleId` runs.
- Precedent already exists for exactly this kind of native bridge: `love.system.vibrate()` is
  implemented in `src/common/ios.mm` (Objective-C++) and exposed to Lua via
  `src/modules/system/wrap_System.cpp`. A StoreKit bridge would follow the identical shape.
- `IPHONEOS_DEPLOYMENT_TARGET` is currently 17.0 — comfortably above StoreKit 2's iOS 15 minimum,
  so the modern API is available if desired.
- **StoreKit.framework is not yet linked** and no IAP code exists anywhere in the checkout — clean slate.

Two viable paths:
- **StoreKit 1 (classic, Objective-C++)** — `SKProductsRequest` / `SKPaymentQueue` /
  `SKPaymentTransactionObserver`, written directly in `ios.mm` using the same
  `@interface ... : NSObject <...Delegate>` style already used there for
  `LoveAudioInterruptionListener`. No new language, no bridging header, fits the current toolchain
  exactly. **Recommended for the MVP.**
- **StoreKit 2 (Swift)** — nicer async/await API, no manual receipt parsing, but Swift has no public
  StoreKit 2 API from Objective-C/C++ directly — needs a small `@objc`-annotated Swift class plus a
  bridging header added to the Xcode project once (manual, one-time; not scripted by `love2d.sh`
  today). Better long-term API, more upfront setup risk.

Implementation shape (either path):
1. Link `StoreKit.framework` to the `love` target.
2. Add native functions (`requestProducts`, `purchase`, `restorePurchases`, `isPurchased`) to
   `ios.h`/`ios.mm`, following `vibrate()`'s pattern — async StoreKit callbacks update a native-side
   cache; Lua polls it each frame rather than needing LÖVE's event-queue internals touched.
3. Expose the functions to Lua via `wrap_System.cpp` (or a small new module), e.g.
   `love.system.iapPurchase(id)` / `love.system.iapIsPurchased(id)`.
4. No-op sensibly on non-iOS platforms (same dispatch pattern `vibrate()` already uses).
5. Validate locally first with Xcode's StoreKit Testing (a local `.storekit` config file) before any
   App Store Connect product exists — de-risks the native bridge before the business side is set up.
6. Only then create the real App Store Connect IAP products and sandbox-test end to end.

Estimated effort: ~1-2 focused days for a developer comfortable with Xcode/Objective-C, most of it in
steps 1-3 above; App Store Connect product setup and sandbox testing (§3 checklist items) is separate,
parallelizable work once the native bridge exists.
