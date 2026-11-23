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
- [ ] Add an `entitlements` table (which systemTypes are unlocked) — persisted like `appSettings`,
      but validated against StoreKit on launch, not just a local flag. OXYGEN is always
      unlocked unconditionally (not entitlement-gated at all)
- [ ] Gate the systems gallery: locked tiles show price + a teaser animation instead of opening the editor
- [ ] Gate schematic creation/editing itself (not just the gallery tap) — a locked system must not be
      reachable via any other path (deep link, catalog, duplicate, etc.)
- [ ] "Restore Purchases" button, and a launch-time StoreKit sync so a reinstall/new device recognizes
      prior purchases
- [ ] Decide bundle pricing (all 5 at a discount) vs. à la carte only — affects App Store Connect product setup
- [ ] Handle "already have a schematic in a system you no longer own" (refund, family-sharing revoke) —
      read-only fallback vs. hidden

## 2. Per-system "signature animation"
The mechanical pieces exist (flow dashes, shimmer, leak spray/puffs, idle pulse). What's missing is a
distinct *identity* per system, not just functional cues:
- [ ] **ELECTRICAL** — define its own idle/hero motion (glow pulse along powered buses exists via `_glow`;
      decide if that's the signature or if it needs more, e.g. a traveling spark)
- [ ] **HYDRAULIC** — red/orange dashes + leak spray + idle pulse (built). Confirm the "powered" red-orange
      color is actually reachable in practice (stayed gray during testing — verify the predicted-color/
      inference path, not just the draw code)
- [ ] **FUEL** — currently shares HYDRAULIC's dash style, tuned slower. Give it its own signature (amber
      tint, viscosity cue; tank wave-fill is a good differentiator to lean into)
- [ ] **BLEED AIR** — shimmer band (built); wants a heat-haze/pressure-wave feel distinct from PRESSURIZATION's
- [ ] **PRESSURIZATION** — shares BLEED AIR's shimmer "just gentler" per the code comment; needs its own
      distinguishing motion (e.g. cabin-altitude-tied pacing) so it doesn't read as a reskin
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
