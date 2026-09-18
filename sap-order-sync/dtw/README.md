# Dummy test items for the order-sync loop — DTW import

Zero-value throwaway items in `HITECH_PRETREADS_LIVE` for exercising the full
ERPNext ⇄ SAP order sync (PASS A create → production order/stage → delivery →
PASS B pull-back) without touching real stock or posting real-value journals.

## Files

- `Seed_DummyItems_OITM.csv` — DTW **oItems** create template (2-row header, DTW
  convention). 10 items, codes `I-14636`…`I-14645`, group `{{GROUP}}`, UDFs
  `U_BeltsPerRoll` / `U_WeightPerRoll` filled.

## Before importing — fill 3 things

1. **Item codes** — the file assumes the current max `I-<n>` is `I-14635`. If SAP
   already has items past that, renumber the `ItemCode` column so all 10 are new.
2. **`{{GROUP}}`** — replace with the **Number** of the item group to file these
   under. Recommended: create a group `ZZ - Test` first
   (*Administration → Setup → Inventory → Item Groups*) and use its Number, so
   every test item is one filter away and outside the `FG%`/`HOT%` patterns the
   daily product sync looks at. An existing generic group works too.
3. Nothing else — no price list rows, no standard cost (keeps every downstream
   movement at zero value).

## Import (DTW)

1. DTW → **Import** → Object **`oItems` (Items)** → data type **Comma** (or Tab —
   re-save the CSV as tab if your DTW is set to tab).
2. Source file: `Seed_DummyItems_OITM.csv`. Map by header (names match OITM
   fields). `ItemCode` is the key.
3. Test run first; then Import. Expect 10 added, 0 failed.
4. If your DTW build rejects `tYES`/`tNO`, change those columns to `Y`/`N`.

## Then seed stock — one Goods Receipt (do this in the B1 client, not DTW)

*Inventory → Inventory Transactions → Goods Receipt*:
- 10 rows, `Item No.` `I-14636`…`I-14645`, `Quantity` **500** each,
  `Warehouse` = whichever warehouse the test Delivery Note will ship from,
  `Unit Price` **0**.
- Add. This posts stock quantity with a zero-value journal.

(500 Kg each so the test Delivery Note can never drive the warehouse negative.)

## After both are done

Tell the agent:
- the final item codes used,
- the item group Number,
- the warehouse code.

The agent then creates the 10 matching ERPNext Items (same codes, HSN `40082940`,
Manna Treads / `Finished Goods - MT` defaults, belt custom fields) + ERPNext
opening stock, and drives the sync loop:

1. New ERPNext Sales Order with 2–3 dummy lines → approve.
2. `Sync-SapOrders.ps1` → PASS A creates the SAP SO, writes back DocNum.
3. B1: Production Order (Sales Order field = the new SAP SO) → Planned → Released
   → Closed, running the sync after each. No component issue / no receipt.
4. B1: Delivery Note (Copy From the SAP SO) → run sync → order shows *Dispatched*.
5. Verify all 8 `custom_sap_*` fields on the ERPNext order.

## Cleanup (all zero-value, low urgency)

Return/Cancel the DN → Close/Cancel the PO → Cancel the SAP SO → set the 10 items
`Frozen`. Agent clears the `custom_sap_*` fields on the ERPNext test order.
