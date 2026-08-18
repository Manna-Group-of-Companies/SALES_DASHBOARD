# Working in this repo

Manna Field Sales — a Flutter phone app for the reps of a rubber and
tread-rubber manufacturer, backed by ERPNext at `mannarubber.m.frappe.cloud`.
Reps take orders in shops, book stock, log visits and trips; managers approve;
production works the floor.

Read this before changing anything. It is the things that are not obvious from
the code and that cost time to rediscover.

---

## 1. The constraint everything bends around

**Server Scripts are not available on this site's plan.** Every business rule
is therefore enforced in the Dart client. There is no backstop: ERPNext will
happily accept a write the app would have refused.

Two consequences you must hold in mind:

- **Anything safety-critical uses optimistic concurrency**, not a lock. Stock
  booking reads the pool, keeps its `modified` timestamp, and writes back
  conditionally; Frappe rejects a stale timestamp. Two reps racing for the last
  rolls resolve to one winner. See the long comment at the top of
  `lib/services/stock_service.dart` — read it before touching booking.
- **Rules must be re-implemented anywhere else that writes.** The dashboard
  (`client/`, in this same repository since 13 August 2026) has its own copy of
  every one of them, in TypeScript. See §6 — and `shared/README.md`, which is
  the mechanism that keeps the two copies honest now that prose alone has
  demonstrably failed to.

---

## 2. Getting anything done

Flutter is not on PATH, and since 13 August 2026 this project is **`app/`
inside the `SALES_DASHBOARD` monorepo** — every command below runs from `app/`,
not from the repository root. See the root `CLAUDE.md` for why.

```bash
cd app
"C:/src/flutter/bin/flutter.bat" analyze          # expect 0 errors
"C:/src/flutter/bin/flutter.bat" test             # ~455 tests, all should pass
"C:/src/flutter/bin/flutter.bat" build apk --release
```

Install on a connected phone:

```bash
ADB="$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe"
"$ADB" install -r build/app/outputs/flutter-apk/app-release.apk
```

**Always build `--release`, never `--profile` or `--debug`.** The phones in the
field have the release build on them, signed with the release key; a
debug-signed build will not install over it without an uninstall, which wipes
the rep's login and any unsent order drafts.

### Signing

`android/key.properties` and `android/app/manna-release.jks` are **gitignored
and exist only on the original machine.** Without them `--release` fails.

If you are picking this up on a new machine you need those two files from
whoever holds them. **Do not generate a new keystore** — a different key cannot
install over the app already on the reps' phones, and every one of them would
have to uninstall and reinstall.

### The version has never been bumped

`pubspec.yaml` still says `1.1.0+2`. `Manna App Settings.minimum_app_version` in
ERPNext gates old builds out. Bump both together when you ship something reps
must have.

### iOS / TestFlight

There is no separate iOS codebase and there should never be one — `app/ios/`
inside **this same repo** is the whole iOS project (Xcode workspace, Info.plist,
signing config), built from the same `lib/` Dart code as Android. It is already
committed. Building for TestFlight needs a Mac (Xcode does not run on Windows),
but it does **not** need a new folder or a fresh `flutter create` — that only
throws away whatever was fixed here.

```bash
cd app
flutter pub get
open ios/Runner.xcworkspace   # not the .xcodeproj — CocoaPods needs the workspace
```

In Xcode: **Signing & Capabilities** → pick your Apple Developer Team (the
project has never had one committed — it's per-signer, set it there, don't
hardcode it) → **Product → Archive** → **Distribute App** → App Store Connect.

Two things already fixed here, so nobody has to rediscover them:

- **The bundle ID was still Flutter's placeholder**, `com.example.mannaFieldSales`
  — not owned by anyone, and App Store Connect will not let you register an App
  ID under it. Fixed 18 Aug 2026 to `com.mannagroup.fieldsales`, matching
  `android/app/build.gradle`'s `applicationId` exactly so the two platforms
  agree on what app this is.
- **Location permissions were entirely missing from `Info.plist`** until 18 Aug
  2026 — Android had them from the start, iOS never did, and every location
  call (punch-in proximity, trip recording, capturing a shop) refused with
  *"Permission definitions not found in the app's Info.plist."* If you see that
  error, you are running a build older than this fix, not hitting a new bug —
  rebuild from current `main`.

Also added: `ITSAppUsesNonExemptEncryption = false` in `Info.plist`, so App
Store Connect stops asking the export-compliance question by hand on every
single upload. The app only speaks HTTPS to ERPNext.

**Not committed, and correctly so — set once per signer, in Xcode:**
`DEVELOPMENT_TEAM` (Signing & Capabilities). It is empty in `project.pbxproj`
on purpose; whoever archives needs their own Apple Developer Team selected
there, and it will write itself into the project file at that point.

**No `Podfile` exists yet.** That's normal for this checkout, not broken —
`flutter pub get` followed by opening the workspace (or `flutter build ios`)
generates it from the plugins in `pubspec.yaml`. Don't hand-write one.

---

## 3. ERPNext

Reached over the REST resource API with token auth. `lib/services/api.dart` is
the single gateway — roughly 3,700 lines, and everything goes through it.

Custom doctypes worth knowing (all `custom = 1`, module `Selling` or `Custom`):

| Doctype | What it holds |
|---|---|
| `Manna Minimum Stock Item` | one pool per item: threshold, reserved counters, in-production figures |
| `Manna Minimum Stock Batch` | dated physical stock behind a pool |
| `Manna Stock Reservation` | one booking, pointing at a Sales Order **or** a Lead Order |
| `Lead Order` / `Lead Order Item` | an order against a lead, before it is a customer |
| `Combined Order` | a week's orders for one customer, rolled up |
| `Sales Visit`, `Trip`, `Trip Log` | field activity |
| `Sales Route` | delivery routes, named `<Rep> - <Place>` |
| `Attendance Log`, `Attendance Regularization`, `Leave Request` | attendance |

### Administering ERPNext

Schema changes have been made through the **Composio MCP connector**
(`ERPNEXT_*` tools) using the `integration@mannarubber.com` account, which is
System Manager. If that connector is unavailable, the same work can be done in
Desk by hand.

---

## 4. Landmines

Every one of these cost real time. They are in rough order of how much.

**Do not edit Dart with multiline `perl -0pi -e` regexes.** It has silently
eaten whole functions twice in this repo — once taking `_decisionSection` with
it. Use the Edit tool, or `sed` on a single line, or delete an exact line range
after reading it.

**Documents returned by the Composio ERPNext tools are not plain mutable
dicts.** `doc['legs'][0]['mode'] = 'Bike'` appears to work and silently does
nothing. Deep-copy first: `d = json.loads(json.dumps(resp))`.

**`custom_production_status` is a Select** accepting exactly `Not Started`,
`In Production`, `Ready`, `Dispatched`. Writing a fine stage name like `Curing`
is rejected and the whole update fails. Per-item stages live in
`Sales Order Item.custom_production_stage`, which is free text, and are rolled
up — see `Api.rollUpStage`.

**A custom field on a submittable doctype needs `allow_on_submit = 1`** or
nobody can change it once the document is submitted. `custom_production_stage`
shipped without it and the floor could not have moved a stage on any submitted
order.

**Frappe replaces rather than merges permissions.** The moment one
`Custom DocPerm` row exists for a doctype, the standard rows stop applying. If
you add one, copy all the standard rows across in the same transaction. To
undo: delete every `Custom DocPerm` for that doctype and the defaults return.

**Deletion order matters.** Frappe refuses to delete a document another one
links to. Reservations → visits → trips; Sales Orders → Combined Orders. A
submitted document must be cancelled (`ERPNEXT_SAVE_DOCS` with
`action: "Cancel"`) before it will delete.

**Releasing stock before deleting orders.** Deleting a Sales Order that holds an
active reservation leaves the pool permanently over-booked, with phantom
bookings nothing in the app can clear. Decrement `custom_reserved_qty` /
`custom_reserved_loose_belts` first.

**Child tables cannot be listed directly** — `Trip Vehicle Leg` and friends
return "Insufficient Permission". Read them through the parent document.

**Unset Link fields read back three different ways**: `null`, `''`, and the
string `'null'` from naive interpolation. Check all three, everywhere.

**`validateStatus: (s) => s != null && s < 500`** in the Dio client is
deliberate — Frappe puts the useful message in the body of a 403 or 417.

**Composio's remote workbench has a hard 3-minute cell limit** and its
`run_composio_tool` is unreliable under `ThreadPoolExecutor`. For bulk work,
loop sequentially with a time budget and run several cells; verify with
`ERPNEXT_GET_COUNT` (whose `filters` want a **dict**, unlike
`ERPNEXT_LIST_DOCUMENTS` which wants a **list of lists**).

---

## 5. Conventions

**Comments say why, never what.** The code says what it does. A comment earns
its place by recording a decision, a constraint, or a trap — usually one a
future reader would otherwise undo. Match the density around you.

**Tests state the rule in their name.** `test('a rep is never blocked by their
own work')`, not `test('filter works')`. Where a test exists because something
broke in production, the comment says what broke. Roughly 400 tests; keep them
green.

**Commit messages explain the problem, then the fix.** Present tense subject
under ~72 characters, body wrapped at 76. Every commit ends with the
`Co-Authored-By` trailer.

**Errors round in the safe direction, and the comment says which way.** An
unrecognised production stage counts as *not started*, never as finished. A
proximity box is sized *outwards*. A failed duplicate check *refuses* the
capture. When you add a rule, decide which way its failure should fall and
write that down.

---

## 6. The web dashboards

A separate build (also with Claude) is producing PWA dashboards for the sales
and production managers. Four documents in `server/` brief it:

| File | Contents |
|---|---|
| `PWA_HANDOFF.md` | foundations: auth, products, weights, minimum stock, the booking protocol |
| `PWA_HANDOFF_MANAGERS.md` | data model and rules for both manager roles |
| `DASHBOARD_UI_SPEC.md` | screen-by-screen interface spec |
| `DASHBOARD_ADDENDUM.md` | everything after the spec — **wins on conflicts** |

**If you change a rule the dashboards also implement, update the addendum in the
same commit.** The approvals in particular must not diverge between the phone
and the web.

---

## 7. Known-wrong, as of 11 August 2026

- **Dispatch is not built.** Batch quantities only change by hand in Desk, so
  every shelf figure is as fresh as the last manual edit.
- **Credit limits and outstanding balances are zero on all 620 customers**, so
  nothing escalates to the GM. Nothing in the app writes those fields.
- **258 of 620 customers have no sales route**, and a route is now required
  before an order can be taken — those customers cannot be ordered from.
- **Production stage lists are placeholders** (`lib/core/production_stages.dart`).
  The real factory sequences have not arrived. Hold them as data.
- **157 items are still on the `Nos` UOM**; `server/item_uom_fix.csv` awaits a
  Data Import.
- **Six items carry invented roll weights.** They are load-bearing — zeroing
  them prices those items at zero.
- **Quality and pattern are parsed out of the item name**
  (`lib/core/item_naming.dart`) because no field holds them. Two Item fields
  would make that unnecessary.
- **Team Orders lists grouped orders individually** rather than collapsing them
  the way the rep's list does.
- **All data before 10 August 2026 was deleted** on 11 August — attendance,
  leave, visits, trips, orders. That was trial data. `kGoLiveDate` in
  `lib/screens/attendance/attendance_calendar_screen.dart` is set to match, so
  earlier days show blank rather than absent.
