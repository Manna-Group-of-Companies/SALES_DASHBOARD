# Server-side rules

## Server Scripts are not available on this plan

The site ran on a plan that allowed Frappe Server Scripts. It no longer does, so
nothing in this folder can execute, and none of the rules below are enforced by
the server any more.

That has a consequence worth being blunt about. A Server Script is the only
thing that can enforce a rule against *whatever* sends the write — the app, a
Desk user, an import, a future integration. Everything the app enforces now, it
enforces only for itself. The rules are still applied on every ordinary path a
rep can take; they are simply no longer impossible to bypass.

Two things are affected today:

| Rule | Was | Is now |
| --- | --- | --- |
| Minimum stock cannot be oversold | Row lock inside a Before Insert script | Compare-and-swap from the app — see below |
| Order placed-at is stamped once and never moves | Before Save script, server clock | App writes it from [ServerClock](../lib/core/server_clock.dart); nothing stops a later edit |

### `attendance_log_time_rules.py`

Kept for reference only. It was **never installed** — the Server Script list on
the site has only ever held `trip_single_active` — and on the current plan it
cannot be. The punch-window rules it describes therefore live solely in
[lib/core/attendance_rules.dart](../lib/core/attendance_rules.dart), which runs
on a phone whose clock the rep controls. [ServerClock](../lib/core/server_clock.dart)
narrows that gap by judging times against the server's clock rather than the
handset's, but a modified client could still write a punch outside the window.

If enforcing that ever matters more than the plan costs, this file is ready to
paste into a Server Script record the day scripting comes back.

## How minimum stock is protected without a script

The full reasoning is at the top of
[lib/services/stock_service.dart](../lib/services/stock_service.dart). In short:

The naive client-side version has a real race. Two reps both read "3 rolls
left", both write a booking for 3, and the warehouse is short. What closes it is
Frappe's own optimistic concurrency — every document carries a `modified`
timestamp, and a save that sends a stale one is refused by the framework. So the
booked total is a running counter on the `Manna Minimum Stock Item` document,
and every booking is a compare-and-swap:

1. read the pool, keeping the `modified` we saw;
2. refuse locally if there is not enough headroom;
3. write the new total back, sending that same `modified`;
4. if the server refuses it, someone else got in first — re-read and retry.

Two reps racing for the last three rolls resolve to exactly one winner. The
loser's write is refused, it re-reads, sees no headroom, and fails cleanly with
a message rather than silently overselling.

**What this does not cover:** anyone editing `custom_reserved_qty` by hand in
Desk while reps are ordering, or a future integration that writes reservations
without following the protocol. Neither is checked by anything. Treat the
reserved counters as machine-owned.

This is the part of the system most worth not breaking, so it is the part with
the most tests. [test/stock_service_test.dart](../test/stock_service_test.dart)
runs against an in-memory Frappe that enforces `modified` exactly as the real
one does, and simulates a competing rep by landing a write in the gap between
our read and our write. The assertion that matters: two reps racing for the last
three rolls leaves **three** booked, not six.

## The other build problem: version skew

Because every rule above runs on the phone, a rep still carrying an older APK
does not know the reserved counters exist and writes straight past them. Nothing
on the server notices; it shows up as a warehouse that is short.

`Manna App Settings` names the oldest build allowed to write, and the app checks
it at sign-in. Two things to understand about that gate:

- It only binds builds that contain the check, so it protects the fleet from
  1.1.0 onward and not before. Getting everyone onto 1.1.0 is a one-time manual
  push.
- It fails open. A rep in a shop with a backend that will not answer keeps
  working; the gate closes on a definite answer and never on silence. Clearing
  `minimum_app_version` turns it off entirely.

## Working without signal

Reads are cached ([lib/services/offline_cache.dart](../lib/services/offline_cache.dart)) —
customers and routes survive a dead network, and every cached answer carries its
age so a rep never quotes a three-day-old outstanding balance believing it is
current. A rejected request is never answered from cache; only a network failure
falls back.

Writes are **not** queued, deliberately. An order that draws on minimum stock is
only real once the pool has been decremented on the server, so accepting one
offline would mean telling a rep "saved" while another rep in signal takes the
last rolls. Orders typed with no signal are held as clearly-labelled drafts
([lib/services/pending_orders.dart](../lib/services/pending_orders.dart)) that
say plainly no stock is held for them, and the booking happens when they are
sent.

## Ordering and unwinding

A reservation names the order it is held against, so the order has to be written
first. [Api.placeOrder](../lib/services/api.dart) creates the Sales Order, books
each minimum-stock line, and — if any booking is refused — releases whatever it
managed to book and deletes the draft order. An order that cannot get its stock
does not survive.

## Schema

Everything the app reads and writes is listed in [SCHEMA.md](SCHEMA.md).
