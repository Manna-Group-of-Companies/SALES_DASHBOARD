#!/usr/bin/env python3
"""Pull credit limits and aged outstanding from SAP B1 into ERPNext.

Reads every company database — Manna Tyre Retreads, Manna Treads and Manna
Tyres UAE — through the Business One **Service Layer**, ages each customer's
open invoices into four buckets, combines the three books per customer, and
writes the result onto the matching ERPNext Customer.

WHY THIS EXISTS
---------------
The buckets are empty on all 1011 ERPNext customers, so the reps' credit
warnings and the GM escalation have never fired against a real ageing. Credit
limits and balances that ARE there were loaded by hand — `custom_sap_last_synced`
is empty on every one of them — so nothing has ever refreshed them.

WHAT IT WRITES
--------------
    custom_credit_limit
    custom_outstanding_balance
    custom_outstanding_0_30 / _30_60 / _60_90 / _90_plus
    custom_sap_last_synced

Matched on ``custom_bp_code`` — the SAP ``CardCode`` — and on nothing else.
620 of 1011 ERPNext customers carry one, all unique, no duplicates. Matching by
trading name is deliberately not offered: two customers can share one, and
crediting the wrong one is not a mistake anybody finds quickly.

THREE COMPANIES, ONE CUSTOMER
-----------------------------
A customer trading with more than one company has a row in each database. They
are one Customer in ERPNext with one set of fields, so the books are combined:
balances and buckets are **summed**, and by default so are credit limits.

Summing both is what keeps the figures comparable. The app checks total
outstanding against the limit; if the outstanding were summed across three
companies and the limit were only the largest of the three, customers would
breach a ceiling nobody set. Set ``credit_limit_policy`` to ``max`` if the
business decides the group limit is the single largest instead.

Every customer found in more than one company is listed in the summary, so a
combination is never silent.

THE BUCKETS ARE COMPUTED, NOT READ
----------------------------------
The Service Layer exposes no ageing report — it gives the balance but not its
age — so the buckets are built from the unpaid remainder of each open A/R
invoice. **They will not always add up to the balance**: payments on account,
journal entries and manual reconciliations move it without belonging to any
invoice. That is expected, `shared/fixtures/credit.json` already treats the
stored total as authoritative and surfaces a mismatch, and this script reports
the size of the gap before anything is written.

If accounts need them to reconcile exactly, this is the wrong approach and the
ageing has to come from a SAP-side query or view instead.

RUNNING IT
----------
    pip install requests
    cp scripts/sap_config.example.json scripts/sap_config.json    # then edit

    # always first: read everything, write nothing, and read the summary
    python scripts/sap_outstanding.py --dry-run

    # then, when the numbers look right
    python scripts/sap_outstanding.py --push

``--push`` is the only thing that writes. Nothing is written without it.

UNTESTED AGAINST A LIVE SAP
---------------------------
Written without Service Layer access, so the request shapes follow the B1 OData
conventions rather than anything observed. The bucketing and merge logic are
tested (``--self-test``). Run ``--dry-run --limit 5`` first and check one
customer you know by heart.
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
except ImportError:  # pragma: no cover
    sys.exit("This needs `requests`. Install it with:  pip install requests")


BUCKETS = ("0_30", "30_60", "60_90", "90_plus")
BUCKET_FIELDS = [f"custom_outstanding_{b}" for b in BUCKETS]

DEFAULTS: dict[str, Any] = {
    "base_url": "https://sap-server:50000/b1s/v1",
    "username": "",
    "password": "",
    "verify_ssl": True,
    "page_size": 200,
    # One entry per company database. base_url/username/password may be
    # overridden per company when a book lives on another server.
    "companies": [],
    "aging_basis": "due",        # 'due' | 'posting'
    "not_due_bucket": "0_30",    # '0_30' | 'exclude'
    "credit_limit_policy": "sum",  # 'sum' | 'max'
    # 'overwrite' lets SAP be the source of truth. 'fill_blanks' protects
    # limits somebody set by hand in ERPNext — 841 customers have one that
    # did not come from SAP.
    "credit_limit_mode": "overwrite",
    "erpnext": {"url": "", "api_key": "", "api_secret": ""},
}


# --------------------------------------------------------------------------
# The rules, kept pure so --self-test can exercise them
# --------------------------------------------------------------------------

def bucket_for(age_days: int, not_due_bucket: str) -> str | None:
    """Which bucket a debt of this age belongs in.

    Inclusive at the bottom, exclusive at the top, so a debt exactly 30 days
    old is 30-60 and is never counted twice. Past 90 is one bucket however old
    it gets — nobody chases 200 days differently from 400.
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


def blank_row(code: str) -> dict[str, Any]:
    return {
        "custom_bp_code": code,
        "card_name": "",
        "custom_credit_limit": 0.0,
        "custom_outstanding_balance": 0.0,
        **{f: 0.0 for f in BUCKET_FIELDS},
        "companies": [],
    }


def merge_company_row(
    into: dict[str, Any], src: dict[str, Any], policy: str
) -> dict[str, Any]:
    """Fold one company's figures for a customer into the combined row.

    Balances and buckets always sum: they are amounts owed, and a customer
    owing in two books owes both. The credit limit follows `policy` — see the
    module docstring for why summing is the default.
    """
    into["card_name"] = into["card_name"] or src.get("card_name", "")
    into["custom_outstanding_balance"] = round(
        into["custom_outstanding_balance"] + src["custom_outstanding_balance"], 2
    )
    for f in BUCKET_FIELDS:
        into[f] = round(into[f] + src[f], 2)

    limit = src["custom_credit_limit"]
    into["custom_credit_limit"] = (
        round(into["custom_credit_limit"] + limit, 2)
        if policy == "sum"
        else max(into["custom_credit_limit"], limit)
    )
    if src.get("company") and src["company"] not in into["companies"]:
        into["companies"].append(src["company"])
    return into


def _money(v: Any) -> float:
    try:
        return round(float(v or 0), 2)
    except (TypeError, ValueError):
        return 0.0


def _parse_date(v: Any) -> date | None:
    try:
        return datetime.strptime(str(v or "")[:10], "%Y-%m-%d").date()
    except ValueError:
        return None


# --------------------------------------------------------------------------
# Service Layer
# --------------------------------------------------------------------------

class ServiceLayer:
    """One logged-in session against one company database.

    A context manager because the logout matters: B1 caps concurrent Service
    Layer sessions per licence, and a scheduled job that exits without logging
    out burns one every run until it times out. With three companies per run
    that is three at a time.
    """

    def __init__(self, cfg: dict[str, Any], company: dict[str, Any]) -> None:
        self.base = str(company.get("base_url") or cfg["base_url"]).rstrip("/")
        self.db = company["company_db"]
        self.label = company.get("label") or self.db
        self.user = company.get("username") or cfg["username"]
        self.pw = company.get("password") or cfg["password"]
        self.page_size = cfg["page_size"]
        self.http = requests.Session()
        self.http.verify = cfg["verify_ssl"]
        if not cfg["verify_ssl"]:
            import urllib3  # noqa: PLC0415

            urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    def __enter__(self) -> "ServiceLayer":
        r = self.http.post(
            f"{self.base}/Login",
            json={"CompanyDB": self.db, "UserName": self.user, "Password": self.pw},
            timeout=60,
        )
        if r.status_code != 200:
            sys.exit(f"[{self.label}] SAP login failed ({r.status_code}): {_err(r)}")
        return self

    def __exit__(self, *_exc: object) -> None:
        try:
            self.http.post(f"{self.base}/Logout", timeout=30)
        except requests.RequestException:
            pass
        self.http.close()

    def page(self, path: str, params: dict[str, str]) -> Iterator[dict[str, Any]]:
        """Every row of an OData collection, following the paging links.

        The Service Layer returns 20 rows and a nextLink. Anything that reads
        only `value` gets the first twenty customers and silently stops.
        """
        url, first = f"{self.base}/{path}", True
        headers = {"Prefer": f"odata.maxpagesize={self.page_size}"}
        while url:
            r = self.http.get(
                url, params=params if first else None, headers=headers, timeout=180
            )
            if r.status_code != 200:
                sys.exit(f"[{self.label}] {path} failed ({r.status_code}): {_err(r)}")
            body = r.json()
            yield from body.get("value", [])
            nxt = body.get("odata.nextLink") or body.get("@odata.nextLink")
            if not nxt:
                return
            url = nxt if nxt.startswith("http") else f"{self.base}/{nxt}"
            first = False


def _err(r: requests.Response) -> str:
    try:
        return json.dumps(r.json().get("error", r.json()), ensure_ascii=False)[:400]
    except ValueError:
        return r.text[:400]


def read_company(
    sl: ServiceLayer, cfg: dict[str, Any], today: date, limit: int | None
) -> dict[str, dict[str, Any]]:
    """One company's customers, with their open invoices already aged."""
    rows: dict[str, dict[str, Any]] = {}
    for bp in sl.page(
        "BusinessPartners",
        {
            "$select": "CardCode,CardName,CreditLimit,CurrentAccountBalance",
            "$filter": "CardType eq 'cCustomer'",
        },
    ):
        code = str(bp.get("CardCode") or "").strip()
        if not code:
            continue
        rows[code] = {
            **blank_row(code),
            "card_name": bp.get("CardName") or "",
            "custom_credit_limit": _money(bp.get("CreditLimit")),
            "custom_outstanding_balance": _money(bp.get("CurrentAccountBalance")),
            "company": sl.label,
        }
        if limit and len(rows) >= limit:
            break

    date_field = "DocDueDate" if cfg["aging_basis"] == "due" else "DocDate"
    seen = orphans = 0
    for inv in sl.page(
        "Invoices",
        {
            "$select": f"CardCode,{date_field},DocTotal,PaidToDate",
            "$filter": "DocumentStatus eq 'bost_Open'",
        },
    ):
        seen += 1
        row = rows.get(str(inv.get("CardCode") or "").strip())
        if row is None:
            orphans += 1
            continue
        owed = _money(inv.get("DocTotal")) - _money(inv.get("PaidToDate"))
        if abs(owed) < 0.005:
            continue
        when = _parse_date(inv.get(date_field))
        # No date to age it by: treated as current rather than dropped, because
        # losing it would understate what the customer owes.
        key = "0_30" if when is None else bucket_for((today - when).days, cfg["not_due_bucket"])
        if key is None:
            continue
        row[f"custom_outstanding_{key}"] = round(row[f"custom_outstanding_{key}"] + owed, 2)

    print(f"  [{sl.label}] {len(rows)} customers, {seen} open invoices"
          + (f", {orphans} against non-customers" if orphans else ""))
    return rows


# --------------------------------------------------------------------------
# ERPNext
# --------------------------------------------------------------------------

class ErpNext:
    def __init__(self, cfg: dict[str, Any]) -> None:
        erp = cfg.get("erpnext") or {}
        for k in ("url", "api_key", "api_secret"):
            if not erp.get(k):
                sys.exit(f"Config is missing erpnext.{k}")
        self.base = erp["url"].rstrip("/")
        self.http = requests.Session()
        self.http.headers["Authorization"] = f"token {erp['api_key']}:{erp['api_secret']}"

    def customers_by_code(self) -> dict[str, dict[str, Any]]:
        """Every coded customer, in one request rather than one per code."""
        r = self.http.get(
            f"{self.base}/api/resource/Customer",
            params={
                "fields": json.dumps(
                    ["name", "custom_bp_code", "custom_credit_limit",
                     "custom_outstanding_balance"]
                ),
                "filters": json.dumps([["custom_bp_code", "is", "set"]]),
                "limit_page_length": 0,
            },
            timeout=120,
        )
        if r.status_code != 200:
            sys.exit(f"ERPNext customer read failed ({r.status_code}): {_err(r)}")
        return {
            str(c["custom_bp_code"]).strip(): c
            for c in r.json().get("data", [])
            if str(c.get("custom_bp_code") or "").strip()
        }

    def update(self, name: str, body: dict[str, Any]) -> str | None:
        r = self.http.put(
            f"{self.base}/api/resource/Customer/{requests.utils.quote(name)}",
            json=body,
            timeout=60,
        )
        return None if r.status_code in (200, 201) else _err(r)


# --------------------------------------------------------------------------

def load_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        sys.exit(f"No config at {path}. Copy scripts/sap_config.example.json to it.")
    cfg = {**DEFAULTS, **json.loads(path.read_text(encoding="utf-8"))}
    if not cfg["companies"]:
        sys.exit("Config lists no companies. Add one entry per SAP company database.")
    for c in cfg["companies"]:
        if not c.get("company_db"):
            sys.exit("Every company needs a company_db.")
    return cfg


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--config", type=Path, default=Path(__file__).with_name("sap_config.json"))
    ap.add_argument("--out", type=Path, default=Path("out/sap_outstanding.json"))
    ap.add_argument("--csv", action="store_true", help="also write a Data Import sheet")
    ap.add_argument("--limit", type=int, help="stop after N customers per company")
    ap.add_argument("--dry-run", action="store_true", help="read and report, write nothing")
    ap.add_argument("--push", action="store_true", help="write the figures into ERPNext")
    ap.add_argument("--self-test", action="store_true", help="check the rules, touch nothing")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    cfg = load_config(args.config)
    today, stamp = date.today(), datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # ---- read every company -------------------------------------------
    combined: dict[str, dict[str, Any]] = {}
    print(f"Reading {len(cfg['companies'])} company database(s)…")
    for company in cfg["companies"]:
        with ServiceLayer(cfg, company) as sl:
            for code, row in read_company(sl, cfg, today, args.limit).items():
                combined.setdefault(code, blank_row(code))
                merge_company_row(combined[code], row, cfg["credit_limit_policy"])

    shared = {c: r["companies"] for c, r in combined.items() if len(r["companies"]) > 1}
    print(f"\n{len(combined)} distinct customers across all books")
    if shared:
        print(f"{len(shared)} trade with more than one company — their figures are combined:")
        for code, where in list(shared.items())[:10]:
            print(f"  {code}: {', '.join(where)}")
        if len(shared) > 10:
            print(f"  … and {len(shared) - 10} more")

    mismatched = [
        (c, r["custom_outstanding_balance"], round(sum(r[f] for f in BUCKET_FIELDS), 2))
        for c, r in combined.items()
        if abs(sum(r[f] for f in BUCKET_FIELDS) - r["custom_outstanding_balance"]) > 1.0
    ]
    if mismatched:
        print(f"\n{len(mismatched)} where buckets do not match the balance "
              f"(payments on account, journals — expected, but check the size):")
        for code, bal, bsum in mismatched[:10]:
            print(f"  {code}: balance {bal} vs buckets {bsum} (diff {round(bal - bsum, 2)})")

    # ---- compare against ERPNext ---------------------------------------
    erp = ErpNext(cfg) if (args.push or not args.dry_run) else None
    if erp:
        known = erp.customers_by_code()
        matched = [c for c in combined if c in known]
        missing = [c for c in combined if c not in known]
        stale = [c for c in known if c not in combined]
        print(f"\nERPNext: {len(known)} coded customers · {len(matched)} matched · "
              f"{len(missing)} in SAP with no ERPNext customer · "
              f"{len(stale)} in ERPNext with no SAP row")

        changes = sum(
            1 for c in matched
            if abs(_money(known[c].get("custom_credit_limit"))
                   - combined[c]["custom_credit_limit"]) > 0.005
        )
        print(f"{changes} credit limits would change "
              f"(credit_limit_mode = {cfg['credit_limit_mode']})")

    # ---- write ----------------------------------------------------------
    if args.dry_run or not args.push:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        payload = [{**r, "custom_sap_last_synced": stamp} for r in combined.values()]
        args.out.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"\nWrote {args.out}")
        if args.csv:
            write_csv(combined, args.out.with_suffix(".csv"), stamp)
            print(f"Wrote {args.out.with_suffix('.csv')}")
        if not args.push:
            print("Nothing written to ERPNext. Re-run with --push when the numbers look right.")
        return

    assert erp is not None
    written = skipped = failed = 0
    for code, row in combined.items():
        target = known.get(code)
        if not target:
            skipped += 1
            continue
        body = {
            "custom_outstanding_balance": row["custom_outstanding_balance"],
            **{f: row[f] for f in BUCKET_FIELDS},
            "custom_sap_last_synced": stamp,
        }
        # Protects a limit somebody set by hand when the mode says so.
        if cfg["credit_limit_mode"] == "overwrite" or not _money(
            target.get("custom_credit_limit")
        ):
            body["custom_credit_limit"] = row["custom_credit_limit"]

        problem = erp.update(target["name"], body)
        if problem:
            failed += 1
            print(f"  ! {code}: {problem}", file=sys.stderr)
        else:
            written += 1
    print(f"\nPushed: {written} updated · {skipped} no matching customer · {failed} failed")


def write_csv(rows: dict[str, dict[str, Any]], path: Path, stamp: str) -> None:
    cols = ["custom_bp_code", "custom_credit_limit", "custom_outstanding_balance",
            *BUCKET_FIELDS, "custom_sap_last_synced"]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for r in rows.values():
            w.writerow({**r, "custom_sap_last_synced": stamp})


def self_test() -> None:
    """Exercise the two rules that decide the numbers. No network."""
    fails = 0
    for age, want in [(-5, "0_30"), (0, "0_30"), (29, "0_30"), (30, "30_60"),
                      (59, "30_60"), (60, "60_90"), (89, "60_90"), (90, "90_plus"),
                      (400, "90_plus")]:
        got = bucket_for(age, "0_30")
        fails += got != want
        print(f"  {'ok' if got == want else 'XX'}  {age:>4}d -> {got}")
    print(f"  {'ok' if bucket_for(-5, 'exclude') is None else 'XX'}  not-due excluded")

    a, b = blank_row("C-1"), blank_row("C-1")
    a.update({"custom_outstanding_balance": 100.0, "custom_outstanding_0_30": 100.0,
              "custom_credit_limit": 25000.0, "company": "Treads"})
    b.update({"custom_outstanding_balance": 50.0, "custom_outstanding_90_plus": 50.0,
              "custom_credit_limit": 10000.0, "company": "UAE"})
    m = merge_company_row(merge_company_row(blank_row("C-1"), a, "sum"), b, "sum")
    ok = (m["custom_outstanding_balance"] == 150.0
          and m["custom_outstanding_0_30"] == 100.0
          and m["custom_outstanding_90_plus"] == 50.0
          and m["custom_credit_limit"] == 35000.0
          and m["companies"] == ["Treads", "UAE"])
    fails += not ok
    print(f"  {'ok' if ok else 'XX'}  two books combine into one customer")

    m2 = merge_company_row(merge_company_row(blank_row("C-1"), a, "max"), b, "max")
    ok2 = m2["custom_credit_limit"] == 25000.0
    fails += not ok2
    print(f"  {'ok' if ok2 else 'XX'}  credit_limit_policy=max takes the largest")
    print("FAILURES:", fails)
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
