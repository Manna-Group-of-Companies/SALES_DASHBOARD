#!/usr/bin/env python3
"""Pull customer credit limits and aged outstanding out of SAP Business One.

WHY THIS EXISTS
---------------
Credit limits and outstanding balances are zero on every customer in ERPNext
(see app/CLAUDE.md section 7), so nothing escalates to the GM and the reps'
credit warnings have never fired against real numbers. SAP holds the real
figures. This reads them through the Business One **Service Layer** and writes
a file the ERPNext side can load.

WHAT IT PRODUCES
----------------
One row per SAP business partner, keyed by ``CardCode``, carrying the credit
limit, the outstanding balance, and the four aging buckets the dashboard and
the phone already read:

    custom_bp_code, custom_credit_limit, custom_outstanding_balance,
    custom_outstanding_0_30, custom_outstanding_30_60,
    custom_outstanding_60_90, custom_outstanding_90_plus

Those are the real ERPNext fieldnames, so the JSON can go straight into a
Frappe Data Import, or through ``--push`` below.

THE BUCKETS ARE COMPUTED HERE, NOT READ
---------------------------------------
The Service Layer exposes no aging report. It gives you the balance
(``CurrentAccountBalance``) but not its age, so the buckets are built from the
open A/R invoices: each invoice's unpaid remainder is placed by how old it is.

That has one consequence worth knowing before you trust the output. **The
buckets will not always add up to the balance.** Payments on account, journal
entries, down payments and manual reconciliations move the balance without
belonging to any invoice. The ERPNext side already expects this — see
`shared/fixtures/credit.json`, which keeps the stored total as the figure the
credit limit is checked against and surfaces a mismatch rather than quietly
picking a winner. This script reports the same mismatch in its summary so you
can see how big it is before loading anything.

WHAT COUNTS AS "OLD"
--------------------
By due date, not posting date: credit control cares how long a debt has been
*overdue*, not how long ago the invoice was raised. An invoice that is not yet
due lands in ``0-30`` — that bucket means "current and up to a month past due",
which is how a receivables ageing is normally read. Both choices are
configurable; see ``aging_basis`` and ``not_due_bucket`` in the config.

RUNNING IT
----------
    pip install requests
    cp scripts/sap_config.example.json scripts/sap_config.json   # then edit it
    python scripts/sap_outstanding.py --config scripts/sap_config.json

    # write somewhere else, and also emit a CSV for a Data Import
    python scripts/sap_outstanding.py --out out/outstanding.json --csv

    # push straight into ERPNext instead of loading by hand (see --push)
    python scripts/sap_outstanding.py --push

``scripts/sap_config.json`` is gitignored. Never commit real credentials.

UNTESTED AGAINST A LIVE SAP
---------------------------
Written without access to your Service Layer, so the request shapes follow the
B1 Service Layer OData conventions rather than anything observed. Run it with
``--limit 5 --dry-run`` first and check the figures against a customer you know
before trusting the whole file.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from datetime import date, datetime
from pathlib import Path
from typing import Any, Iterator

try:
    import requests
except ImportError:  # pragma: no cover - the one dependency
    sys.exit("This needs `requests`. Install it with:  pip install requests")


# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

DEFAULTS: dict[str, Any] = {
    # Service Layer root. Port 50000 is the B1 default. The /b1s/v1 suffix is
    # part of the address, not optional.
    "base_url": "https://sap-server:50000/b1s/v1",
    "company_db": "",
    "username": "",
    "password": "",
    # Most B1 Service Layers ship a self-signed certificate. Turning this off
    # is common on an internal network and a bad idea over the open internet;
    # it is left ON here so that choice has to be made deliberately.
    "verify_ssl": True,
    # 'due' ages from DocDueDate — how overdue the debt is, which is the
    # question credit control is asking. 'posting' ages from DocDate instead.
    "aging_basis": "due",
    # Where an invoice that is not yet due goes. '0_30' reads that bucket as
    # "current and up to a month past due", which is the usual convention.
    # 'exclude' leaves future invoices out of the buckets entirely — the
    # balance still includes them, so expect a larger mismatch.
    "not_due_bucket": "0_30",
    # Service Layer pages at 20 rows unless told otherwise.
    "page_size": 200,
    # Only needed for --push.
    "erpnext": {"url": "", "api_key": "", "api_secret": ""},
}


def load_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        sys.exit(
            f"No config at {path}.\n"
            f"Copy scripts/sap_config.example.json to {path} and fill it in."
        )
    cfg = {**DEFAULTS, **json.loads(path.read_text(encoding="utf-8"))}
    missing = [k for k in ("base_url", "company_db", "username", "password") if not cfg[k]]
    if missing:
        sys.exit(f"Config is missing: {', '.join(missing)}")
    cfg["base_url"] = cfg["base_url"].rstrip("/")
    return cfg


# --------------------------------------------------------------------------
# Service Layer
# --------------------------------------------------------------------------

class ServiceLayer:
    """A logged-in Service Layer session.

    Used as a context manager so the session is always closed. That matters
    more than it looks: B1 caps concurrent Service Layer sessions per licence,
    and a script that exits without logging out burns one until it times out.
    Run this on a schedule without the logout and you will eventually lock
    everybody out.
    """

    def __init__(self, cfg: dict[str, Any]) -> None:
        self.cfg = cfg
        self.http = requests.Session()
        self.http.verify = cfg["verify_ssl"]
        if not cfg["verify_ssl"]:
            import urllib3  # noqa: PLC0415 - only when the user opted out

            urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    def __enter__(self) -> "ServiceLayer":
        r = self.http.post(
            f"{self.cfg['base_url']}/Login",
            json={
                "CompanyDB": self.cfg["company_db"],
                "UserName": self.cfg["username"],
                "Password": self.cfg["password"],
            },
            timeout=60,
        )
        if r.status_code != 200:
            # The Service Layer puts the useful part in the body, not the code.
            sys.exit(f"SAP login failed ({r.status_code}): {_err(r)}")
        return self

    def __exit__(self, *_exc: object) -> None:
        try:
            self.http.post(f"{self.cfg['base_url']}/Logout", timeout=30)
        except requests.RequestException:
            # Nothing useful to do about it, and it must not mask a real error
            # from the body of the script.
            pass
        self.http.close()

    def page(self, path: str, params: dict[str, str]) -> Iterator[dict[str, Any]]:
        """Yield every row of an OData collection, following the paging links.

        The Service Layer returns 20 rows at a time and an ``odata.nextLink``,
        so anything that just reads ``value`` gets the first twenty customers
        and silently stops. ``Prefer: odata.maxpagesize`` raises the page size;
        the nextLink loop is still needed because it is a maximum, not a
        promise.
        """
        url = f"{self.cfg['base_url']}/{path}"
        headers = {"Prefer": f"odata.maxpagesize={self.cfg['page_size']}"}
        first = True
        while url:
            r = self.http.get(
                url, params=params if first else None, headers=headers, timeout=180
            )
            if r.status_code != 200:
                sys.exit(f"SAP {path} failed ({r.status_code}): {_err(r)}")
            body = r.json()
            yield from body.get("value", [])

            nxt = body.get("odata.nextLink") or body.get("@odata.nextLink")
            if not nxt:
                return
            # The link is relative to the service root on most builds and
            # absolute on some. Both appear in the wild.
            url = nxt if nxt.startswith("http") else f"{self.cfg['base_url']}/{nxt}"
            first = False


def _err(r: requests.Response) -> str:
    try:
        return json.dumps(r.json().get("error", r.json()), ensure_ascii=False)[:400]
    except ValueError:
        return r.text[:400]


# --------------------------------------------------------------------------
# The rule: how a balance is aged
# --------------------------------------------------------------------------

BUCKETS = ("0_30", "30_60", "60_90", "90_plus")


def bucket_for(age_days: int, not_due_bucket: str) -> str | None:
    """Which bucket a debt of this age belongs in.

    Boundaries are inclusive at the bottom and exclusive at the top, so a debt
    exactly 30 days old is 30-60 and never counted twice. Anything past 90 is
    one bucket however old it gets — nobody chases 120 differently from 200.
    """
    if age_days < 0:
        return None if not_due_bucket == "exclude" else not_due_bucket
    if age_days < 30:
        return "0_30"
    if age_days < 60:
        return "30_60"
    if age_days < 90:
        return "60_90"
    return "90_plus"


def _money(v: Any) -> float:
    try:
        return round(float(v or 0), 2)
    except (TypeError, ValueError):
        return 0.0


def _parse_date(v: Any) -> date | None:
    s = str(v or "")[:10]
    try:
        return datetime.strptime(s, "%Y-%m-%d").date()
    except ValueError:
        return None


# --------------------------------------------------------------------------
# Pulling it together
# --------------------------------------------------------------------------

def fetch_partners(sl: ServiceLayer, limit: int | None) -> dict[str, dict[str, Any]]:
    """Customers, with their limit and balance as SAP holds them."""
    out: dict[str, dict[str, Any]] = {}
    params = {
        "$select": "CardCode,CardName,CreditLimit,CurrentAccountBalance",
        # Customers only. Suppliers and leads share the table.
        "$filter": "CardType eq 'cCustomer'",
    }
    for bp in sl.page("BusinessPartners", params):
        code = str(bp.get("CardCode") or "").strip()
        if not code:
            continue
        out[code] = {
            "custom_bp_code": code,
            "card_name": bp.get("CardName") or "",
            "custom_credit_limit": _money(bp.get("CreditLimit")),
            "custom_outstanding_balance": _money(bp.get("CurrentAccountBalance")),
            **{f"custom_outstanding_{b}": 0.0 for b in BUCKETS},
        }
        if limit and len(out) >= limit:
            break
    return out


def apply_aging(
    sl: ServiceLayer,
    rows: dict[str, dict[str, Any]],
    cfg: dict[str, Any],
    today: date,
) -> tuple[int, int]:
    """Age every open A/R invoice into its customer's buckets.

    Returns (invoices seen, invoices whose customer was not in the BP set) —
    the second number should be zero, and is worth looking at when it is not:
    it means invoices exist against partners the customer filter excluded.
    """
    date_field = "DocDueDate" if cfg["aging_basis"] == "due" else "DocDate"
    params = {
        "$select": f"CardCode,{date_field},DocTotal,PaidToDate",
        # Open only. A closed invoice has been paid and ages nothing.
        "$filter": "DocumentStatus eq 'bost_Open'",
    }

    seen = orphans = 0
    for inv in sl.page("Invoices", params):
        seen += 1
        code = str(inv.get("CardCode") or "").strip()
        row = rows.get(code)
        if row is None:
            orphans += 1
            continue

        # What is still owed on this document, not what it was raised for.
        owed = _money(inv.get("DocTotal")) - _money(inv.get("PaidToDate"))
        if abs(owed) < 0.005:
            continue

        when = _parse_date(inv.get(date_field))
        if when is None:
            # No date to age it by. Treated as current rather than dropped:
            # losing it entirely would understate what the customer owes.
            key = "0_30"
        else:
            key = bucket_for((today - when).days, cfg["not_due_bucket"])
            if key is None:
                continue

        row[f"custom_outstanding_{key}"] = round(
            row[f"custom_outstanding_{key}"] + owed, 2
        )
    return seen, orphans


def summarise(rows: dict[str, dict[str, Any]], tolerance: float = 1.0) -> dict[str, Any]:
    """What is worth knowing before this file is loaded anywhere."""
    mismatched = []
    for code, r in rows.items():
        bucket_sum = round(sum(r[f"custom_outstanding_{b}"] for b in BUCKETS), 2)
        if abs(bucket_sum - r["custom_outstanding_balance"]) > tolerance:
            mismatched.append((code, r["custom_outstanding_balance"], bucket_sum))
    return {
        "customers": len(rows),
        "with_balance": sum(1 for r in rows.values() if r["custom_outstanding_balance"]),
        "with_limit": sum(1 for r in rows.values() if r["custom_credit_limit"]),
        "mismatched": mismatched,
    }


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

def write_json(rows: dict[str, dict[str, Any]], path: Path, synced_at: str) -> None:
    payload = [{**r, "custom_sap_last_synced": synced_at} for r in rows.values()]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")


def write_csv(rows: dict[str, dict[str, Any]], path: Path, synced_at: str) -> None:
    """A Frappe Data Import sheet.

    The header row is ERPNext fieldnames, so the importer maps them without
    anybody choosing columns by hand — which is where a bucket ends up in the
    wrong field and nobody notices for a month.
    """
    cols = [
        "custom_bp_code",
        "custom_credit_limit",
        "custom_outstanding_balance",
        *[f"custom_outstanding_{b}" for b in BUCKETS],
        "custom_sap_last_synced",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for r in rows.values():
            w.writerow({**r, "custom_sap_last_synced": synced_at})


def push_to_erpnext(
    rows: dict[str, dict[str, Any]], cfg: dict[str, Any], synced_at: str
) -> None:
    """Write the figures onto the matching ERPNext Customers.

    Matched on ``custom_bp_code``, which is the only thing tying the two
    systems together. A partner whose code is on no customer is reported and
    skipped — never guessed at by name, because two customers can share a
    trading name and crediting the wrong one is not a mistake you find quickly.
    """
    erp = cfg.get("erpnext") or {}
    if not (erp.get("url") and erp.get("api_key") and erp.get("api_secret")):
        sys.exit("--push needs erpnext.url, api_key and api_secret in the config.")

    base = erp["url"].rstrip("/")
    http = requests.Session()
    http.headers["Authorization"] = f"token {erp['api_key']}:{erp['api_secret']}"

    written = skipped = failed = 0
    for code, r in rows.items():
        q = http.get(
            f"{base}/api/resource/Customer",
            params={"filters": json.dumps([["custom_bp_code", "=", code]]),
                    "fields": json.dumps(["name"]), "limit_page_length": 1},
            timeout=60,
        )
        found = q.json().get("data", []) if q.status_code == 200 else []
        if not found:
            skipped += 1
            continue

        body = {k: v for k, v in r.items() if k.startswith("custom_")}
        body["custom_sap_last_synced"] = synced_at
        u = http.put(
            f"{base}/api/resource/Customer/{requests.utils.quote(found[0]['name'])}",
            json=body,
            timeout=60,
        )
        if u.status_code in (200, 201):
            written += 1
        else:
            failed += 1
            print(f"  ! {code}: {_err(u)}", file=sys.stderr)

    print(f"Pushed: {written} written, {skipped} no matching customer, {failed} failed")


# --------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--config", type=Path, default=Path(__file__).with_name("sap_config.json"))
    ap.add_argument("--out", type=Path, default=Path("out/sap_outstanding.json"))
    ap.add_argument("--csv", action="store_true", help="also write a Data Import sheet")
    ap.add_argument("--limit", type=int, help="stop after N customers (for a first look)")
    ap.add_argument("--dry-run", action="store_true", help="print the summary, write nothing")
    ap.add_argument("--push", action="store_true", help="write straight into ERPNext")
    args = ap.parse_args()

    cfg = load_config(args.config)
    today = date.today()
    synced_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    with ServiceLayer(cfg) as sl:
        print("Reading business partners…")
        rows = fetch_partners(sl, args.limit)
        print(f"  {len(rows)} customers")

        print("Ageing open invoices…")
        seen, orphans = apply_aging(sl, rows, cfg, today)
        print(f"  {seen} open invoices" + (f", {orphans} against non-customers" if orphans else ""))

    s = summarise(rows)
    print(
        f"\n{s['customers']} customers · {s['with_balance']} with a balance · "
        f"{s['with_limit']} with a credit limit"
    )
    if s["mismatched"]:
        # Not an error. Payments on account and journal entries move the
        # balance without belonging to an invoice, so some gap is normal —
        # but a large one means the buckets are not describing the balance.
        print(f"{len(s['mismatched'])} where the buckets do not match the balance:")
        for code, bal, bsum in s["mismatched"][:10]:
            print(f"  {code}: balance {bal} vs buckets {bsum} (diff {round(bal - bsum, 2)})")
        if len(s["mismatched"]) > 10:
            print(f"  … and {len(s['mismatched']) - 10} more")

    if args.dry_run:
        print("\nDry run — nothing written.")
        return

    write_json(rows, args.out, synced_at)
    print(f"\nWrote {args.out}")
    if args.csv:
        csv_path = args.out.with_suffix(".csv")
        write_csv(rows, csv_path, synced_at)
        print(f"Wrote {csv_path}")
    if args.push:
        push_to_erpnext(rows, cfg, synced_at)


if __name__ == "__main__":
    main()
