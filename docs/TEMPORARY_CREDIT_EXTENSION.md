# Temporary Credit Extension – 10-day payment commitment

Built 16 November 2026 to the user's strict instruction: **a separate workflow
added beside everything that exists**. Order approval, credit-period requests,
credit conditions and the SAP credit sync work exactly as before. The rules are
pinned in [`shared/fixtures/credit_extension.json`](../shared/fixtures/credit_extension.json),
and four implementations test against it.

## How it works

1. **Request.** A rep (phone) or a manager (dashboard) chooses one of their
   orders that is waiting for approval and takes the customer past the SAP
   credit limit. The request records the credit limit, outstanding, overdue,
   order amount and excess at that moment.
   - It goes to the **Manager**.
   - It goes straight to the **GM** if the customer ever missed a commitment
     or already has an extension running.
2. **Manager review.** The manager reviews:
   - customer name and code, SAP credit limit, outstanding, overdue;
   - order amount and excess;
   - recent SAP invoices with paid amounts;
   - every earlier extension and missed commitment.

   The manager enters the **temporary additional credit**, the **payment
   commitment date**, the **reason** and the **remarks**, then presses
   **Approve & Push to SAP**. It is refused, and the manager can only
   **Send to GM** or **Reject**, when:
   - the amount is 0;
   - the amount is past the manager's authority (*Manna Credit Extension
     Settings → Manager's Approval Authority*; 0 means none);
   - the date is more than 10 calendar days from today;
   - the reason or the remarks are missing;
   - the customer missed a commitment before, or has an extension running.
3. **SAP.** The job raises the customer's `CreditLimit` by the amount. Before
   the write it saves the original limit, and after it reads the figure back.
   The SAP reference (company / code / old → new / SAP's update stamp) and
   every request and response are kept on the extension.
4. **Payments.** The job counts confirmed SAP incoming payments of the
   customer, dated from the approval to the commitment date:
   - only payments that are not cancelled and not drafts;
   - cash + transfer + cheques + cards + bills;
   - each one once, by DocEntry.

   The status shows **Paid / Partially Paid / Not Paid** and what remains.
5. **Paid** by the date: the original limit goes back in SAP.
   **Not paid in full** by the date: **Payment Commitment Overdue**. The job:
   - marks the commitment as missed;
   - escalates it to the GM and notifies the manager and the GM, once each;
   - puts the original limit back.
6. **GM.**
   - **Approve & Push to SAP**: a new amount, date and required remarks. This
     makes a *new* extension linked to the overdue one; nothing is
     overwritten.
   - **Reject**: required remarks; the status becomes *Rejected by GM*; the
     manager is notified. A rejected request can never be sent to SAP.

## What SAP taught us (TEST, 16 Nov 2026)

SAP refuses a credit limit above the customer's **commitment limit**
(`MaxCommitment`, OCRD.DebtLine): *"Commitment limit must be greater than
credit limit"*. On TEST all 652 customers with a limit have the two equal.
**The user chose to move both together:**
- the raise lifts the commitment limit to at least the new credit limit, in
  the same write;
- the restore puts both back;
- either figure changed by somebody in between is **never overwritten**: the
  extension is marked *Needs Review* and the GM and the approver are told.

## Report

### New files
| File | What |
|---|---|
| `shared/fixtures/credit_extension.json` | The rules, as cases |
| `app/server/credit_extension.py` | Server Script `manna_credit_extension` (API): every action and permission |
| `app/server/credit_extension_doctypes.json` | The five doctypes |
| `app/server/test_credit_extension.py` | The script's rules against the fixture |
| `app/server/install_credit_extension_local.py` | Installs on the local ERPNext only |
| `sap-credit-sync/Sync-CreditExtensions.ps1` | The SAP job: raise, payments, restore |
| `sap-credit-sync/Test-CreditExtensions.ps1` | The job's decisions against the fixture, offline |
| `sap-credit-sync/Register-CreditExtensionTask.ps1` | The office server's scheduled task (preview unless `-Apply`) |
| `app/lib/core/credit_extension.dart`, `app/test/credit_extension_test.dart` | Phone rule + tests |
| `app/lib/screens/requests/credit_extension_screen.dart` | Phone: list, new request, review |
| `client/src/domain/creditExtension.ts`, `client/src/domain/__tests__/creditExtension.test.ts` | Dashboard rule + tests |
| `client/src/api/creditExtensions.ts` | Dashboard API calls |
| `client/src/features/credit/CreditExtensionsPage.tsx` | Dashboard page `/credit-extensions` |

### Existing files modified — additions only
| File | Added |
|---|---|
| `app/lib/services/api.dart` | The extension calls, and two offline-queue kinds |
| `app/lib/screens/home/home_dashboard.dart` | A *Temporary Credit* tile, for reps and the GM |
| `app/lib/screens/manager/manager_dashboard_screen.dart` | A *Temporary Credit* card, with a waiting count |
| `app/lib/screens/home/unsent_items_screen.dart` | An icon for the two new queue kinds |
| `client/src/app/routes.tsx` | Route `/credit-extensions` (sales managers and the GM) |
| `client/src/components/layout/AppShell.tsx` | A *Temporary Credit* sidebar entry, for managers and the GM |
| `app/server/credit_period_request.py` | Not this feature. One comprehension became a loop, because before Python 3.12 a Server Script comprehension cannot see the script's names. Behaviour is unchanged |
| `app/server/install_credit_period_local.py` | Adds missing fields to an existing doctype |

### Database (ERPNext doctypes; nothing existing changed)
- **Manna Credit Extension** (`TCE-#####`): the request, its figures at
  request time, the approval, the escalation and the rejection, and the SAP
  fields:
  - original and raised credit limit and commitment limit;
  - SAP reference and error;
  - restore status and reference;
  - the payment commitment: paid, remaining, payment status, missed.
- **Manna Credit Extension Log** (child): the audit history; every action, who
  did it, their role, the time and the remarks.
- **Manna Credit Extension Payment** (child): the SAP payments counted, each
  once by DocEntry.
- **Manna Credit Extension SAP Log** (child): every SAP request and response.
- **Manna Credit Extension Settings** (Single): the manager's approval
  authority, plus the job's flag and last result.

### New API endpoint
`POST /api/method/manna_credit_extension` with `action` =
- `eligible`, `list`, `detail`, `history`: reads;
- `submit`, `approve`, `reject`, `escalate`, `retry`: the workflow;
- `sap_event`: the SAP job only (SAP Sync Bot or System Manager).

### Permissions
- The doctypes are System Manager's, and SAP Sync Bot can read them.
- Everything else goes through the Server Script:
  - a rep sees their own requests and asks;
  - a manager sees their team's, and decides within their authority;
  - the GM sees all and decides all.
- No existing role or permission changed.

### SAP integration
- A new job, beside the credit sync, which it does not change. It reuses the
  credit sync's SAP login, certificate pin, paging and ERPNext helpers by
  reading them out of that file.
- It writes only `BusinessPartners(...).CreditLimit` and `MaxCommitment`, in
  the sync's one company (Manna Treads).
- Duplicates are prevented:
  - the original is saved before the write;
  - a repeat finds "already" and does not write again;
  - an extension cannot be raised while another of the customer's is still
    raised;
  - payments are counted once by DocEntry;
  - each status moves once, so each escalation and notification happens once.
- On a SAP failure the extension becomes *SAP Push Failed*, with SAP's message,
  and the approver may push it again.

### Test results (16 Nov 2026)
**Rules against the fixture**

| Where | Tests |
|---|---|
| Server Script | 7 suites |
| Phone | 54 |
| Dashboard | 54 |
| SAP job | 19 |

**Whole suites**: Flutter 1,234 pass; dashboard 928 pass, typecheck clean;
`Test-CreditPeriodPush` 30/30; `Test-InvoiceMirror` 23/23.

**Local ERPNext, through the real Server Script as the demo rep, manager and
GM: 24/24 steps.** These covered:
- eligibility and routing;
- every validation check;
- approve & push;
- refusal of a double approval;
- Send to GM;
- GM rejection with notifications;
- who sees what, and the review data;
- refusal of a SAP report from anyone but the job.

**TEST SAP (TEST_MANNA_TREADS, customer C-1694), every step dry-run first**
- the first raise was refused by SAP (the commitment-limit rule): *SAP Push
  Failed*, then retried;
- raise 35,000 → 45,000 (both limits);
- paid in full: 23,532 against 10,000, then restored;
- 40,000 raised to 75,000; partly paid (35,347), overdue, escalated to the GM,
  notified once, restored;
- after the miss, a new request went straight to the GM;
- the GM renewed for 20,000 (a new record, 55,000), it went unpaid, overdue,
  restored, then the GM rejected it and a retry was refused;
- a second run of the job changed nothing;
- C-1694 ended at 35,000 / 35,000, as it started.

To place the paid, partial and unpaid cases over real TEST payments, the
extensions' approval and commitment dates were moved back on the local
ERPNext; that was a test step, not part of the feature.

**Existing workflows checked after the change**
- the credit sync, dry-run on TEST: clean, nothing to change;
- a credit-period request submitted, rejected, and the current term refused;
- order-approval, credit-condition and credit-period tests all green in both
  apps.

### Not done — needs the user
- Live ERPNext: create the five doctypes and the Server Script; set the
  manager's authority.
- The office server: copy `Sync-CreditExtensions.ps1`, then
  `Register-CreditExtensionTask.ps1 -Apply`. That is when live SAP credit
  limits start to be written.
- Release: the dashboard deploy and a phone build.
- Not run on a phone or in a browser for this feature: the screens are
  analysed and typechecked, and their rules tested.

## 17 November 2026: the gaps against the spec, closed

The user approved these defaults on 17 Nov 2026. The rules are in the same
fixture; each item says where it is enforced.

| Gap | What changed | Where |
|---|---|---|
| Unlimited manager extensions for a customer who always pays | At most **2 manager-approved extensions per customer in any 90 days**; the next goes to the GM. Checked when asked **and** when approved. GM approvals do not count. 0 sends everything to the GM | Server Script; fixture `routing`, `manager_window`; both apps show "n of 2 in 90 days" |
| "Configured approval authority" was one figure for everyone, set to 0 | **Each manager may have their own figure** (Settings → `authorities`), else the shared default. 0 means none. The GM sets both on the dashboard (*Approval authority* on `/credit-extensions`); the Settings track changes | Server Script `settings`; fixture `authority` |
| Escalation only happened when the office-server job ran | **`manna_credit_extension_watch`**, a Scheduler Server Script at 09:00, escalates any `Active` extension past its date, marked *not yet checked against SAP* (`overdue_unchecked`), and sets the SAP restore pending. It never marks a miss itself: the job's next payment count does (*Paid in time after all*, or *missed*). It also tells the GM when the job has not run for six hours while extensions wait | `app/server/credit_extension_watch.py`; fixture `watchdog`, `late_check`; the job now counts unchecked ones too |
| Notifications reached nobody | Both apps list this login's extension notifications (`alerts`, `seen`) — *Alerts* on the dashboard page, the top of the phone's list | Server Script; both apps |
| The order's own page said nothing | The order page in both apps shows any extension asked on it | `TemporaryCreditNote.tsx`, `TemporaryCreditStrip` |

Unchanged on purpose (the user's defaults): the over-credit order approval
(`credit_commitment.json`); Manna Treads only; the SAP reference is
company/BP/old → new/SAP's update stamp, since a limit change has no SAP
document number.

### Live install, when the user says so
1. The new child doctype **Manna Credit Extension Authority**, then the new
   fields on Manna Credit Extension Settings (`authorities`,
   `manager_cap_count`, `manager_cap_days`, `last_watch_run`,
   `last_watch_result`, and *Track Changes* on) and on Manna Credit Extension
   (`overdue_unchecked`) — `credit_extension_doctypes.json`.
2. Settings: **cap 2 in 90 days** (an unset Int reads 0, which would send
   every request to the GM), and the managers' authority.
3. Server Scripts: `manna_credit_extension` updated,
   `manna_credit_extension_watch` new (Scheduler Event, Cron `0 9 * * *`).
4. The office server's `Sync-CreditExtensions.ps1` replaced.

### Tests (17 Nov 2026)
- Fixture suites: Server Script 11/11, phone 65, dashboard 66, SAP job 19.
- Whole suites: Flutter 1,245 pass; dashboard 940 pass, typecheck clean.
- Local ERPNext, through the real Server Scripts as the demo rep, manager
  and GM, in one transaction rolled back after: **42/42** — the settings
  (who may read and set them, version history), each manager's own
  authority, 10 days, the watchdog (escalates once, leaves the commitment
  day to the customer, notifies both), the late count (paid after all;
  missed under a GM rejection), the cap (the third to the GM; asked before
  the cap filled and approved after is refused), a GM rejection never
  reaching SAP, the job-stale alert, alerts read and marked seen, the
  order's extension found from the order.
- Dashboard in the browser against the local copy, as the demo GM: alerts,
  the review with the "not yet checked" note and the cap line, the
  authority settings saved, the note on the order page.
- Phone: analysed and tested; not run on a device.
