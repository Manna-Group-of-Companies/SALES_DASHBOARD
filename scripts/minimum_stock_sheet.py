#!/usr/bin/env python3
"""Build the daily shelf-count sheet for the production manager.

WHY THIS IS A SCRIPT AND NOT A SAVED FILE

The sheet has one row per `Manna Minimum Stock Batch`, pre-filled with what
ERPNext currently believes is on the shelf. That set changes: pools are added
as items move onto the minimum-stock list, and a stale sheet would silently
drop the new ones -- an item with no row is an item nobody counts.

Regenerate it whenever the pool list changes. It is cheap and it is the only
way the sheet stays complete.

WHAT IT WRITES TO, AND THE TRAP UNDERNEATH

The sheet updates `Manna Minimum Stock Batch` -- the actual rubber on the
shelf. It must never touch `Manna Minimum Stock Item`, whose `qty` is the
MINIMUM TO HOLD, not the shelf. Confusing the two is the standing trap in this
module and it fails in the expensive direction: promising stock that is not
there.

Reservations are not in this sheet either. They live on the Item
(`custom_reserved_qty`), and the apps subtract them from the shelf figure
themselves. So the count that goes in here is EVERYTHING physically present,
including rolls already booked but not yet dispatched. Reporting only free
stock subtracts the bookings twice.

USAGE

    python scripts/minimum_stock_sheet.py --key KEY --secret SECRET \
        [--out minimum_stock_daily_update.csv] [--sample 3]

`--sample N` also writes an N-row file, for proving the import mapping before
running it over all of them.
"""

import argparse
import csv
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

SITE = "https://mannarubber.m.frappe.cloud"

# The header must carry the doctype's LABELS, not its fieldnames: Frappe's Data
# Import matches on the label shown in Desk. Verified against the live doctype
# on 8 September 2026 -- if someone relabels a field there, this breaks loudly
# at mapping time rather than importing into the wrong column.
HEADER = ["ID", "Item", "Remaining", "Remaining Loose Belts", "In Stock Since"]


def fetch(path, key, secret, **params):
    url = SITE + urllib.parse.quote(path)
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": f"token {key}:{secret}"})
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read().decode())["data"]
    except urllib.error.HTTPError as e:
        sys.exit(f"ERPNext said {e.code} for {path}: {e.read().decode()[:200]}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--key", required=True)
    p.add_argument("--secret", required=True)
    p.add_argument("--out", default="minimum_stock_daily_update.csv")
    p.add_argument("--sample", type=int, default=0)
    a = p.parse_args()

    batches = fetch(
        "/api/resource/Manna Minimum Stock Batch", a.key, a.secret,
        fields='["name","item_code","qty","loose_belts","batch_date"]',
        limit_page_length=0,
    )
    pools = fetch(
        "/api/resource/Manna Minimum Stock Item", a.key, a.secret,
        fields='["item_code"]', limit_page_length=0,
    )

    # A pool with no batch is a real state -- it means an empty shelf, and it is
    # exactly what production needs to see. But it has no row to count on, so
    # say so rather than letting the item vanish from the sheet.
    have = {str(b["item_code"]) for b in batches}
    missing = sorted({str(r["item_code"]) for r in pools} - have)

    # Two batches for one item would put two rows on the sheet fighting over one
    # shelf, and the second import would overwrite the first.
    seen, dupes = set(), []
    for b in batches:
        code = str(b["item_code"])
        if code in seen:
            dupes.append(code)
        seen.add(code)

    rows = sorted(batches, key=lambda r: str(r["item_code"]))

    def write(path, data):
        # utf-8-sig: Excel misreads a plain UTF-8 CSV and mangles every item
        # name carrying the mojibake from the old import.
        with open(path, "w", newline="", encoding="utf-8-sig") as f:
            w = csv.writer(f)
            w.writerow(HEADER)
            for r in data:
                q = float(r["qty"] or 0)
                w.writerow([
                    r["name"],
                    r["item_code"],
                    int(q) if q == int(q) else q,
                    int(r["loose_belts"] or 0),
                    r["batch_date"],
                ])

    write(a.out, rows)
    print(f"wrote {a.out}: {len(rows)} rows")
    if a.sample:
        sample_path = a.out.replace(".csv", f"-sample{a.sample}.csv")
        write(sample_path, rows[: a.sample])
        print(f"wrote {sample_path}: {a.sample} rows, for proving the mapping first")

    print(f"pools: {len(pools)} | batches: {len(batches)}")
    if dupes:
        print(f"  WARNING {len(dupes)} item(s) have more than one batch: {dupes[:5]}")
        print("  Two rows would fight over one shelf. Merge them before importing.")
    if missing:
        print(f"  WARNING {len(missing)} pool(s) have NO batch, so no row to count:")
        for m in missing[:10]:
            print(f"     {m}")


if __name__ == "__main__":
    main()
