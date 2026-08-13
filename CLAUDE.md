# Working in this repo

Two apps against one ERPNext site (`mannarubber.m.frappe.cloud`), for a rubber
and tread-rubber manufacturer.

| Directory | What it is |
|---|---|
| `client/` | React PWA — the managers' dashboard. **Hosted**, on Cloudflare Pages |
| `app/` | Flutter — the reps' phones. Not hosted; built as an APK and side-loaded |
| `shared/` | Rules both must obey, as fixtures. Read `shared/README.md` first |

They were separate repositories until 13 August 2026. They are one repository
now for a single reason: **the same business rule is written twice, in two
languages, and the copies drift.** Within a day of each other both sides
implemented per-line discounts and disagreed about the discount ceiling — see
`shared/DIVERGENCES.md`.

Each directory has its own briefing with everything specific to it:
`app/CLAUDE.md` and `client/DEPLOY.md`. Read the one you are working in. This
file only covers what spans both.

---

## The constraint everything bends around

**Server Scripts are not available on this site's plan.** Every business rule
is enforced in the client — in *both* clients. There is no backstop: ERPNext
will accept a write either app would have refused.

So a rule is only as good as its weakest implementation. A check that exists in
`client/` and not in `app/` is not a check.

---

## Before you change a shared rule

Anything about **money, approval, or stock** is shared. Prices, discounts,
credit escalation, the booking protocol, who may approve what.

1. Look in `shared/fixtures/` for a case that already pins it.
2. Change the fixture and **both** implementations in the same commit.
3. If the two sides ought to differ, say why in `shared/DIVERGENCES.md`. Do not
   leave it undocumented — the next person will read it as a bug and "fix" one
   side into disagreeing with the other.

Cosmetic differences between a phone and a dashboard are fine and always will
be. These are not.

---

## Hosting, and why the layout is what it is

Cloudflare Pages builds **only** `client/`:

| Setting | Value |
|---|---|
| Root directory | `client` |
| Build output | relative to that root |
| Build watch paths | `client/*`, `shared/*` |

The whole repository is cloned into the build container; only `client/`'s build
output is published. Nothing in `app/` is ever served — it is cloned, ignored
and discarded.

**The watch paths matter.** Without them every Flutter commit triggers a
dashboard deploy, which spends the build allowance on builds that change
nothing.

`client/` stayed exactly where it was so that none of this needed
reconfiguring. That is the only reason the two apps sit at different depths.

---

## Building each side

```bash
# dashboard
cd client && npm install && npm run dev

# app  (Flutter is not on PATH)
cd app
"C:/src/flutter/bin/flutter.bat" analyze     # expect 0 errors
"C:/src/flutter/bin/flutter.bat" test        # ~455 tests, all should pass
"C:/src/flutter/bin/flutter.bat" build apk --release
```

**Always build the app `--release`.** The phones in the field carry the
release build, signed with the release key; a debug-signed build will not
install over it without an uninstall, which wipes the rep's login and any
unsent order drafts. `app/android/key.properties` and
`app/android/app/manna-release.jks` are gitignored and exist on one machine
only — **do not generate a new keystore**, a different key cannot install over
what the reps already have.

---

## Administering ERPNext

Schema changes go through the **Composio MCP connector** (`ERPNEXT_*` tools) as
`integration@mannarubber.com`, which is System Manager. Failing that, Desk by
hand. `app/CLAUDE.md` §4 lists the traps — they cost real time and every one of
them is still true.
