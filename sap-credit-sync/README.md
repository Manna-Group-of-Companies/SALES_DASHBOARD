# SAP Business One (Manna Treads) -> ERPNext credit-limit sync

One-way copy of **customer credit limits** from a **single** SAP Business One
company database (Manna Treads) into ERPNext's `custom_credit_limit`.

Scope: just the credit limit, one company. Whatever CardCodes come back from the
Manna Treads database **are** the set of customers we sync. There is no
ERPNext-side "Treads customers" filter and the script does not invent one.

## Files

| File                       | Purpose                                                    |
| -------------------------- | -------------------------------------------------------- |
| `Sync-SapCreditLimits.ps1` | The whole job. Dry-run first, then schedule it.          |
| `config.example.json`      | Template. Copy to `config.json`, fill in, keep out of git. |
| `Invoke-SapSyncPoller.ps1` | Run by the `SAP-Watch-Credit` flag watcher when someone presses Sync; claims a run and starts the sync. |
| `poller.config.example.json` | Template for the poller's `poller.config.json` (bot key, paths). Keep out of git. |
| `rep-map.json`             | SAP sales employee -> ERPNext Sales Person, for the new-customer step. Read on every run. |
| `Test-CreditPeriodPush.ps1` | Offline. The credit-period push (16 Nov 2026) against `shared/fixtures/credit_period_request.json` and a stand-in Service Layer. |
| `Sync-CreditExtensions.ps1` | Temporary credit extensions (16 Nov 2026): raises a customer's CreditLimit (and MaxCommitment with it) for an approved extension, counts SAP payments against the commitment, puts both back. A separate job; borrows this sync's functions without running or changing it. Writes nothing without `-Apply`. See `docs/TEMPORARY_CREDIT_EXTENSION.md` |
| `Test-CreditExtensions.ps1` | Offline. That job's decisions against `shared/fixtures/credit_extension.json` |
| `Register-CreditExtensionTask.ps1` | Registers `SAP-Credit-Extensions` (every 5 min, SYSTEM). Preview unless `-Apply`; run elevated |
| `.gitignore`               | Keeps `config.json` / `poller.config.json` / `login.json` / logs out of git. |

## Where it runs

The copy that runs is **`C:\Users\eldhose\sap-credit-sync`** on the office
server, not this folder. `sap-order-sync/Register-FlagWatchTasks.ps1` points the
`SAP-Watch-Credit` task there. This folder was brought into git on
5 Nov 2026 from that copy and its `.bak-*` files (see the git log). Change it
here, then copy the changed files across to deploy; the live `config.json` and
`poller.config.json` stay only on the server.

## Config keys — exactly what the script reads

The script reads **only** these keys and **never falls back to a default** for a
required one (a mistyped key that silently becomes a default is how the wrong
site gets written to). Unrecognised keys are logged as a `WARN` and ignored.

```jsonc
{
  "erpnext": {
    "site":       "https://mannarubber.m.frappe.cloud",  // required
    "api_key":    "...",                                  // required
    "api_secret": "..."                                   // required  -> sent as  Authorization: token key:secret
  },
  "sap": {
    "url":        "https://192.168.100.200:50000/b1s/v1", // required  (Service Layer root)
    "username":   "...",                                  // required
    "password":   "...",                                  // required
    "verify_ssl": false,                                  // optional, default true. false => skip TLS validation (self-signed cert on :50000)
    "pinned_cert_sha256": "AB12...",                      // optional (5 Nov 2026). With verify_ssl false: accept the SAP host ONLY with this certificate SHA-256
    "page_size":  200,                                    // optional, default 200. Prefer: odata.maxpagesize; nextLink is followed regardless
    "companies": [                                        // required, EXACTLY ONE entry (array kept so a 2nd book can be added later; the merge logic was removed)
      { "name": "Manna Treads", "company_db": "MANNA_TREADS_LIVE" }   // both required
    ]
  },
  "write_mode":    "overwrite",   // required. "overwrite" = SAP is authoritative | "fill_blanks" = only set currently-empty limits
  "skip_codes":    [],            // optional. SAP CardCodes to never write
  "skip_customer_prefixes": [],   // optional (12 Nov 2026). ERPNext customers whose name starts with one of these are left out, e.g. ["DEMO - "] on the local copy, where demo customers share their real twin's code. Live: none
  "log_dir":       "./logs",      // optional. Relative paths resolve against the script folder
  "sync_invoices":  true,         // optional, default true (5 Nov 2026). Mirror SAP A/R invoices into the SAP Invoice doctype
  "invoices_since": "2026-04-01", // optional, default 1 April of the current financial year. Open invoices are mirrored whatever their date
  "log_keep_days": 30,            // optional, default 30. Older dated logs deleted at start of each run
  "push_payment_terms": false     // optional, default false (16 Nov 2026). true = change the payment term in SAP for credit-period requests pushed from ERPNext
}
```

### If you already made `login.json`

`login.json` matches the schema above **except**: it also carries
`multi_company` and `stamp_sync_field`. Both are dead now — single-company is the
only mode, and stamping written customers is unconditional — so the script logs a
`WARN` for each. Delete those two lines when convenient. Everything else in
`login.json` is read as-is; just copy it to `config.json` (or pass its path).

## Behaviour that matters

- **Match on `custom_bp_code` only.** Never by name.
- **A coded ERPNext customer whose code is not in the Manna Treads database is
  left completely alone** — no limit write, no `0`, no `null`, no field clear, no
  sync stamp. "Not in the SAP book" = "no information", never "zero". The count
  is reported as `in ERPNext, not in Manna Treads: N` and the skip is stated in
  the log every run.
- **A matched customer whose SAP `CreditLimit` is `0`** is also skipped (0 is the
  Business One default meaning "no figure", and writing it would strip a
  hand-typed limit off a live account). Reported as `SAP limit 0 skipped: N`.
- **`custom_sap_last_synced`** is stamped **only** on customers actually written,
  so from the first real run it distinguishes a SAP-sourced limit from a
  hand-typed one.
- **Never touched:** `custom_outstanding_*`, and ERPNext's standard
  `credit_limits` child table (writing it would switch on ERPNext's own
  order-blocking credit control).
- Timestamp uses the **machine's** local time. Run the schedule on a host whose
  timezone matches the Frappe site (IST) so the value reads correctly.

## Credit-period requests (16 Nov 2026)

A manager (up to 30 days) or the GM (31 to 40) approves a customer's new
payment term in ERPNext and presses **Push to SAP**. That marks the
`Manna Credit Period Request` **Sending to SAP** and raises this sync's flag.
The sync then, inside its one SAP session and **before** it reads the
customers:

1. reads SAP's payment terms (`PaymentTermsTypes`);
2. for each request **Sending to SAP**, reads the business partner, checks the
   request again (`Get-TermPushPlan`: an approval of the right rank for the
   days, the term still in SAP under the same name and days, 40 days at most),
   `PATCH`es `BusinessPartners('<code>')` with `PayTermsGrpCode` only, and
   reads it back;
3. reports each one through the `manna_credit_period_request` Server Script:
   **In SAP** (with the term before), or back to **Approved** with SAP's error.

Because the push comes before the customer read, the new term reaches
ERPNext's `custom_payment_terms` in the same run. A request whose answer could
not be sent stays **Sending to SAP** and is tried again; a term SAP already
holds is reported without writing, so a repeat never writes twice.

It writes **the payment term only**, never the credit limit, and only in this
sync's one company. **Nothing is written unless `push_payment_terms` is
`true`**: with it off (the default) the run logs what it would do and leaves
the requests waiting. `-DryRun` likewise writes nothing, to SAP or ERPNext.

Every run also copies SAP's payment terms, as `[{code, name, days}]`, to
`SAP Sync Control.payment_terms_json`, which is the list both apps offer.
The field is in `app/server/credit_period_request_doctypes.json`; until it
exists the run logs a WARN.

The login the sync uses must be able to change business partners in SAP, and
in ERPNext needs the `SAP Sync Bot` role (read on the doctype; the Server
Script accepts its answers) or System Manager.

## SAP Invoice mirror (5 Nov 2026)

The credit history under Team Targets (each customer's invoices, with paid and
balance) reads the ERPNext doctype **`SAP Invoice`**, which this sync fills in
the same SAP login. Its definition is `app/server/sap_invoice_doctypes.json`;
until it exists on the site the run logs a WARN and skips the mirror, so
deploying the script first changes nothing.

- One row per SAP invoice, named `<company>-<DocEntry>` (DocNum restarts each
  financial year). Fields: customer, invoice_no (DocNum), posting_date,
  due_date, total, paid (PaidToDate), balance, status (Open / Closed).
- Holds every uncancelled invoice dated on or after `invoices_since`, plus every
  invoice still open, for customers ERPNext holds by `custom_bp_code`.
- Only changed rows are written. A row no longer in that set (cancelled in SAP,
  or closed and older than `invoices_since`) is deleted, except that a run which
  would delete more than half of a mirror of 20+ rows deletes nothing.
- A failed invoice read leaves the mirror untouched. `-Limit` caps these writes too.
- The login the sync uses needs read/write/create/delete on `SAP Invoice`; the
  doctype gives that to System Manager and SAP Sync Bot.

Test it on this PC with `MannaHRM/localdev/sap/run-credit-sync.mjs`: local
ERPNext and TEST_MANNA_TREADS only. The script refuses a TEST_ company with a
site that is not on this PC, and a live company with one that is.

## First run

```powershell
cd C:\Users\eldhose\sap-credit-sync
Copy-Item "$env:USERPROFILE\Downloads\login.json" .\config.json   # or fill in config.example.json

# DRY RUN FIRST - reads everything, writes nothing, prints the full summary
.\Sync-SapCreditLimits.ps1 -ConfigPath .\config.json -DryRun
```

Read the summary. Sanity-check `matched`, `in ERPNext, not in Manna Treads`,
`credit limits that WOULD change`, and any non-standard-code WARN. Then:

```powershell
.\Sync-SapCreditLimits.ps1 -ConfigPath .\config.json -Limit 5   # a few real writes; inspect in ERPNext
.\Sync-SapCreditLimits.ps1 -ConfigPath .\config.json            # the rest
```

Re-running is safe: a limit already equal to SAP is skipped, and the timestamp
only moves when the limit changes.

## Scheduling (Windows Scheduled Task)

Run once daily at a quiet hour as a **dedicated service account** (not a person,
so it keeps working when someone changes their password). Put the script and
`config.json` where that account can read them (not under `C:\Users\eldhose`),
e.g. `C:\Scripts\sap-credit-sync\`.

```powershell
$dir = 'C:\Scripts\sap-credit-sync'

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
    "-File `"$dir\Sync-SapCreditLimits.ps1`" -ConfigPath `"$dir\config.json`""
)
$trigger  = New-ScheduledTaskTrigger -Daily -At 2:30am
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Register-ScheduledTask -TaskName 'SAP-Treads-CreditSync' `
    -Description 'Daily one-way sync of Manna Treads customer CreditLimit from SAP B1 to ERPNext custom_credit_limit.' `
    -Action $action -Trigger $trigger -Settings $settings `
    -User 'MANNA\svc-sapsync' -Password 'THE-SERVICE-ACCOUNT-PASSWORD' -RunLevel Limited
```

Check results:

```powershell
Get-ScheduledTaskInfo -TaskName 'SAP-Treads-CreditSync'   # LastTaskResult 0 = OK
Get-Content (Get-ChildItem "$dir\logs\sap-credit-sync-*.log" | Sort-Object Name)[-1].FullName -Tail 40
```

The script exits non-zero on any SAP failure or ERPNext write failure, so a bad
run shows as **Last Run Result != 0x0** in Task Scheduler.
