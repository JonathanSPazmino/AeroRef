# AeroRef — Per-System Monetization Roadmap

Business model: each schematic system type sells separately in the App Store. Users pay to
unlock each type, so each one needs its own unique, attractive animation to justify a
standalone purchase.

**Pricing decision (locked in):**
- Free tier: **OXYGEN system** — the simplest of all systems, chosen specifically for this
  role. Built (see §0) — catalog items, medium file, and signature shimmer/color all in place.
- All other systems (ELECTRICAL, HYDRAULIC, FUEL, BLEED AIR, PRESSURIZATION): paid, one flat
  price across all of them. Exact price TBD — decided when the app is ready to ship, not before.

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
- [x] Decide the free tier — see pricing decision above (OXYGEN free, rest paid at one flat TBD price)
- [x] Add an `entitlements` table (which systemTypes are unlocked) — persisted like `appSettings`
      (`appSettings.entitlements`, keyed by systemType, OXYGEN never gets a key and reads as
      entitled unconditionally via `_isSystemTypeEntitled`). StoreKit-launch validation still
      TODO — this is the local-flag half only, same placeholder status `schematicUnlocked` already
      had. The paywall's "Simulate Purchase" button is the testing backdoor —
      `unlockSchematicFeature()` grants every paid systemType at once (matches the
      one-flat-price-for-all-paid-systems pricing decision)
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
- [ ] Decide bundle pricing (all 5 at a discount) vs. à la carte only — affects App Store Connect product setup
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
- [ ] Settle on a consistent visual language across the 5 (color, motion style, leak behavior) so they read
      as a family of products, not unrelated reskins

## 3. In-App Purchase / App Store technical setup
- [x] Feasibility investigated — see Appendix below. **Verdict: feasible.**
- [ ] Pick StoreKit 1 (Objective-C++, fits existing `ios.mm` pattern, no new language) vs. StoreKit 2
      (Swift, nicer API, needs a bridging header)
- [ ] Link `StoreKit.framework` in `love.xcodeproj`
- [ ] Add native purchase/restore/query functions (`ios.mm` + a small Lua-facing wrap, mirroring the
      existing `vibrate()`/`getSafeArea()` pattern)
- [ ] Create 5 (or 6, with a bundle) In-App Purchase products in App Store Connect — non-consumable,
      one per system
- [ ] Sandbox-test purchase, restore, and failure/cancel flows on-device before anything else here matters
- [ ] Receipt validation: on-device/local-flag is fine for this scale — make the call explicitly
- [x] Price tier decision — flat price across all paid systems (OXYGEN free); exact number TBD at ship time

## 4. Functional polish / known gaps
- [x] Fix the fluid-vanishing bug in `model/fluid.lua`'s `step()` (a self-looping pipe run drains its
      source with no credited receiver) — fixed; verified live (reservoir held steady at 27%/102L for
      60s of idle simulation, vs. continuous drain before the fix)
- [ ] Verify the ELECTRICAL "powered" color actually triggers in normal use (inference/prediction path)
- [ ] Sweep each system's catalog for the same "generic sink, user-named" treatment ACTUATOR got, where
      it makes sense (e.g. does ELECTRICAL need a generic LOAD beyond LIGHT/MOTOR/HEATER?)
- [ ] Confirm save/load round-trips cleanly for a schematic in each system after a purchase lapses/returns
- [ ] Undo/redo and snapshot behavior sanity-checked per system now that each is a standalone paid feature

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
