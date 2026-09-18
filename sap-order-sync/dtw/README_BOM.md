# Dummy BOM for the order-sync test loop — DTW import

Goal: a Production Order can be raised against the `I-146xx` test FG items
without touching real items, by giving each one a one-line BOM whose only
component is a zero-value dummy item.

## Files

| File | What |
|---|---|
| `Seed_DummyComponent_OITM.csv` | one new item, `I-14646` — the dummy component, zero cost |
| `BOM_Header.csv` | 10 rows — one BOM per test FG item (`I-14636`…`I-14645`) |
| `BOM_Lines.csv` | 10 rows — each BOM's single line: `I-14646` qty 1 |

`BOM_Header.csv` / `BOM_Lines.csv` are a **matched pair** — DTW's Bill of
Materials import is a header+lines object, the same shape as a Sales Order
and its line items. `RecordKey` links a row in Lines back to its row in
Header (0-based; row `RecordKey=3` in Lines belongs to the BOM at
`RecordKey=3` in Header). Import them **together** in DTW's BOM wizard, not
as two separate single-object imports.

## Before importing

1. **Fill `{{WAREHOUSE}}`** in both `BOM_Header.csv` and `BOM_Lines.csv` —
   find-and-replace with the warehouse code you want the BOM (and later the
   Production Order) to use.
2. If SAP already has an item numbered `I-14646` or higher, bump the
   component's code in `Seed_DummyComponent_OITM.csv` and in every row of
   `BOM_Lines.csv` to match.
3. **Field names are my best-effort guess at the standard schema** (`Code`,
   `TreeType`, `Quantity`, `Warehouse` for the header; `ItemCode`, `Quantity`,
   `Warehouse`, `LineNum` for lines) — I could not confirm them against a live
   BOM on this SAP build (Service Layer has been down). **If your DTW
   generates its own Bill of Materials template with different column names**
   (Tools → Import Template → open object "Bill of Materials" / "Production
   BOM"), use ITS header row with these same values — same one-field fix as
   the `ItemsGroupCode` issue on the items import.

## Import order

1. **DTW → Import → `oItems`** with `Seed_DummyComponent_OITM.csv` (same as
   the 10 test items earlier).
2. **DTW → Import → Bill of Materials**, header file `BOM_Header.csv`, lines
   file `BOM_Lines.csv`. Test run first; expect 10 BOMs created, 0 failed.

## Still needed after this (not DTW — one screen in the B1 client)

**Stock**, at zero value, so a Production Order can actually issue the
component and a later Delivery Note can ship the FG:

*Inventory → Inventory Transactions → Goods Receipt*, `Unit Price` **0**,
warehouse = the same one used above:
- `I-14646` (component) — a large quantity, e.g. **5000 Kg** (it's consumed
  1:1 per FG unit produced across however many test Production Orders you run)
- Any of `I-14636`…`I-14645` that doesn't already have stock — **500 Kg** each
  (only needed for the ones you'll actually ship on a Delivery Note)

## Then — a Production Order

*Production → Production Order*: Product No. = one of the `I-146xx` items
(the BOM now auto-fills its component line), **Sales Order** field = the SAP
Sales Order you want it linked to (e.g. DocNum 381), status **Planned**. Move
it Planned → Released → Closed, running `Sync-SapOrders.ps1` after each —
`custom_sap_production_order` / `custom_sap_production_stage` should land on
the ERPNext order each time.

If you want the component actually **Issued** (rather than leaving the PO at
Planned/Released/Closed with no postings), that consumes stock at whatever
value the component is carrying — zero, as built here, so it's a zero-value
GL entry either way.
