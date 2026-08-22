/**
 * Dispatch Planning — the production manager's replacement for hand-picking
 * "Dispatched" off a line's stage dropdown.
 *
 * A dispatch bundles any number of lines from any number of Ready orders
 * onto one vehicle and one date. It is saved to ERPNext on every change so it
 * survives a refresh, and it ends exactly two ways: **Dispatch**, which locks
 * it and makes what was planned what went, or **Cancel**, which deletes it.
 *
 * There is no third ending where it is kept "as a draft" for later. A dispatch
 * still sitting at Draft holds its lines against every other planner — see
 * `stagedElsewhere` — so one parked indefinitely makes stock unplannable that
 * no van is coming to collect, and nothing on screen tells the next person
 * apart from stock genuinely spoken for.
 *
 * **The quantity is decided once, when the line is added.** A partial load is
 * planned as a partial load — 7 of 10 — and the remaining 3 stay on the order
 * as Left, ready for the next van. There is deliberately no second screen
 * asking again how much actually left: it asked a question the planner had
 * already answered with the stepper, and made them say the same number twice.
 *
 * Lines carry the customer as well as the route: a van is loaded per
 * customer, and a route does not say whose pallet is whose when two
 * customers sit on one round.
 */

import { useEffect, useMemo, useState } from 'react';
import type { Dispatch, DispatchableLine } from '@/domain/types';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import {
  Alert,
  Badge,
  Button,
  Card,
  Empty,
  Field,
  Input,
  Stepper,
  Tabs,
  type TabDef,
} from '@/components/ui';
import { RefreshButton } from '@/components/common/RefreshButton';
import '@/components/layout/layout.css';
import '@/features/orders/orders.css';
import './production.css';

type View = 'ready' | 'drafts';

/** What the draft panel is editing locally before the next autosave. */
interface DraftLine {
  salesOrder: string;
  salesOrderItem: string;
  itemCode: string;
  itemName: string;
  route: string;
  /** Whose goods these are — the van is loaded per customer, not per route. */
  customerName: string;
  plannedRolls: number;
  plannedLooseBelts: number;
}

/** "3 rolls + 2 belts", or "—" when there is nothing. Belts only when some. */
function qtyText(rolls: number, belts: number): string {
  const parts: string[] = [];
  if (rolls > 0) parts.push(`${rolls} rolls`);
  if (belts > 0) parts.push(`${belts} belts`);
  return parts.join(' + ') || '—';
}

function toDraftLines(d: Dispatch): DraftLine[] {
  return d.lines.map((l) => ({
    salesOrder: l.salesOrder,
    salesOrderItem: l.salesOrderItem,
    itemCode: l.itemCode,
    itemName: l.itemName,
    route: l.route,
    customerName: l.customerName,
    plannedRolls: l.plannedRolls,
    plannedLooseBelts: l.plannedLooseBelts,
  }));
}

export function DispatchPlanningPage() {
  const user = useAppSelector(selectUser);

  /*
   * This manager's own unit, fixed — not a dropdown.
   *
   * Each unit's dispatches are planned by its own production manager, so a
   * unit picker offered a choice nobody has to make and let one manager load
   * a van against another unit's orders. Undefined (the flag is not on every
   * User yet) means unfiltered, which is what the picker defaulted to anyway.
   */
  const unit = user?.productionUnit ?? '';
  const [view, setView] = useState<View>('ready');
  const [readyLines, setReadyLines] = useState<DispatchableLine[]>([]);
  const [drafts, setDrafts] = useState<Dispatch[]>([]);
  const [tick, setTick] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  /*
   * Whether the draft panel is open, held explicitly rather than derived from
   * `draftId != null || lines.length > 0`.
   *
   * Deriving it deadlocked the screen: "Start a new dispatch" clears both, so
   * the panel closed again the instant it was asked to open, and the Add
   * buttons — gated on the same flag — stayed disabled. There was no way to
   * add the first line to a new dispatch at all. A new dispatch has no id and
   * no lines by definition, so neither can stand in for "is one open".
   */
  const [draftOpen, setDraftOpen] = useState(false);

  // The draft currently being built. `id` is unset until the first save.
  const [draftId, setDraftId] = useState<string | null>(null);
  const [vehicle, setVehicle] = useState('');
  const [dispatchDate, setDispatchDate] = useState('');
  const [lines, setLines] = useState<DraftLine[]>([]);
  const [saving, setSaving] = useState(false);
  const [addQty, setAddQty] = useState<Record<string, { rolls: number; looseBelts: number }>>({});

  const [dispatching, setDispatching] = useState(false);

  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Promise.all([Api.production.listDispatchableLines(unit || undefined), Api.production.listDispatchDrafts(unit || undefined)])
      .then(([ready, d]) => {
        if (!live) return;
        setReadyLines(ready);
        setDrafts(d);
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : 'Could not read dispatch planning.');
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
    };
  }, [unit, tick]);

  /**
   * How much of each line THIS draft has already staged.
   *
   * A staged line used to be dropped from the list entirely, which hid the
   * very thing a planner needs to see: add 3 of 10 ready rolls and the row
   * vanished, taking the other 7 with it, with nothing on screen saying they
   * were still owed. It stays, and reports what is left.
   */
  const stagedQty = useMemo(() => {
    const m = new Map<string, { rolls: number; belts: number }>();
    for (const l of lines) {
      m.set(l.salesOrderItem, { rolls: l.plannedRolls, belts: l.plannedLooseBelts });
    }
    return m;
  }, [lines]);

  /*
   * Lines staged in somebody's OTHER draft are also off the table.
   *
   * "Remaining to dispatch" counts what has actually gone, so a line sitting
   * planned in another draft still reads as fully available — and the same
   * rolls could be loaded onto two vans, each planner believing they had
   * them. The draft being edited is excluded, or its own lines would
   * disappear from the list the moment they were added.
   */
  const stagedElsewhere = useMemo(() => {
    const keys = new Set<string>();
    for (const d of drafts) {
      if (d.id === draftId) continue;
      for (const l of d.lines) keys.add(l.salesOrderItem);
    }
    return keys;
  }, [drafts, draftId]);

  /** One ready line, with what this draft has taken of it and what is left. */
  interface ReadyRow {
    line: DispatchableLine;
    addedRolls: number;
    addedBelts: number;
    leftRolls: number;
    leftBelts: number;
    /** Nothing left to add — the whole ready quantity is on this dispatch. */
    full: boolean;
  }

  /*
   * Grouped by ORDER, not by route.
   *
   * A van is loaded order by order: the question at the tailgate is "is
   * SAL-ORD-00131 complete", not "what else is on this round". Grouping by
   * route scattered one order's lines across the screen whenever a customer
   * had two items, and there was no way to see an order was half-loaded.
   */
  const readyByOrder = useMemo(() => {
    const groups = new Map<string, { head: DispatchableLine; rows: ReadyRow[] }>();
    for (const l of readyLines) {
      if (stagedElsewhere.has(l.salesOrderItem)) continue;
      const staged = stagedQty.get(l.salesOrderItem);
      const addedRolls = staged?.rolls ?? 0;
      const addedBelts = staged?.belts ?? 0;
      const leftRolls = Math.max(0, l.remainingRolls - addedRolls);
      const leftBelts = Math.max(0, l.remainingLooseBelts - addedBelts);
      const row: ReadyRow = {
        line: l,
        addedRolls,
        addedBelts,
        leftRolls,
        leftBelts,
        full: leftRolls <= 0 && leftBelts <= 0,
      };
      const g = groups.get(l.salesOrder) ?? { head: l, rows: [] };
      g.rows.push(row);
      groups.set(l.salesOrder, g);
    }
    return [...groups.entries()].sort(([, a], [, b]) =>
      a.head.customerName.localeCompare(b.head.customerName),
    );
  }, [readyLines, stagedQty, stagedElsewhere]);

  /**
   * How many lines still have something addable.
   *
   * Fully-staged rows stay on screen — that is how a planner sees the order
   * is complete — but they are not "ready to add" any more, so counting them
   * would keep the tab claiming work that is done.
   */
  const readyCount = useMemo(
    () => readyByOrder.reduce((n, [, g]) => n + g.rows.filter((r) => !r.full).length, 0),
    [readyByOrder],
  );

  const tabs: TabDef<View>[] = [
    // Counted off the list actually rendered, not `readyLines - lines`, which
    // double-subtracted anything staged in another draft.
    { id: 'ready', label: `Ready to add (${readyCount})` },
    /*
     * Not "drafts" any more — planning ends in Dispatch or Cancel, and Cancel
     * deletes. What can still land here is one nobody finished: the tab was
     * closed, or the browser died, mid-plan. Those are worth surfacing rather
     * than hiding, because an unfinished dispatch still holds its lines out
     * of everyone else's Ready to add and is otherwise invisible.
     */
    { id: 'drafts', label: `Unfinished (${drafts.length})` },
  ];

  const startNew = () => {
    setDraftOpen(true);
    setDraftId(null);
    setVehicle('');
    setDispatchDate('');
    setLines([]);
    setDone(null);
    // Straight to the list they are about to pick from — a new dispatch with
    // no lines is only useful next to the things that can go into it.
    setView('ready');
  };

  /** Clear the panel. Local only — says nothing about what is in ERPNext. */
  const closePanel = () => {
    setDraftOpen(false);
    setDraftId(null);
    setVehicle('');
    setDispatchDate('');
    setLines([]);
  };

  /**
   * Abandon the dispatch being planned, and delete it.
   *
   * There is deliberately no "leave it for later". A dispatch still sitting
   * at Draft holds its lines against everybody else — `stagedElsewhere`
   * subtracts them from what anyone can add — so a half-planned one left
   * behind makes stock unplannable that no van is coming for, and the next
   * planner has no way to tell that from stock genuinely spoken for.
   */
  const cancelDispatch = async () => {
    // Nothing written yet: no vehicle or date has been entered, so no
    // document exists to delete and clearing the panel is the whole job.
    if (!draftId) {
      closePanel();
      return;
    }
    setSaving(true);
    setError(null);
    try {
      await Api.production.discardDispatch(draftId);
      closePanel();
      setTick((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not cancel the dispatch.');
    } finally {
      setSaving(false);
    }
  };

  const resume = (d: Dispatch) => {
    setDraftOpen(true);
    setDraftId(d.id);
    setVehicle(d.vehicle);
    setDispatchDate(d.dispatchDate ?? '');
    setLines(toDraftLines(d));
    setView('ready');
    setDone(null);
  };

  const persist = async (next: { vehicle?: string; dispatchDate?: string; lines?: DraftLine[] }) => {
    if (!user) return;
    const nextVehicle = next.vehicle ?? vehicle;
    const nextDate = next.dispatchDate ?? dispatchDate;
    const nextLines = next.lines ?? lines;
    setSaving(true);
    setError(null);
    try {
      const saved = await Api.production.saveDispatchDraft({
        id: draftId ?? undefined,
        vehicle: nextVehicle,
        dispatchDate: nextDate || undefined,
        unit: unit || undefined,
        lines: nextLines.map((l) => ({
          salesOrder: l.salesOrder,
          salesOrderItem: l.salesOrderItem,
          itemCode: l.itemCode,
          plannedRolls: l.plannedRolls,
          plannedLooseBelts: l.plannedLooseBelts,
        })),
        user,
      });
      setDraftId(saved.id);
      setTick((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not save the draft.');
    } finally {
      setSaving(false);
    }
  };

  /**
   * Stage some of a ready line, or add to what is already staged of it.
   *
   * Adding to an existing row rather than appending a second one: a line
   * dispatched in two goes — 3 rolls now, 7 when the next pallet is wrapped —
   * is still one line on one vehicle, and two rows for the same
   * `salesOrderItem` would be written to the dispatch as duplicates and
   * confirmed twice at the tailgate.
   *
   * Capped at what is actually left, so a stale screen cannot plan out more
   * than the order still owes.
   */
  const addLine = (row: ReadyRow) => {
    const l = row.line;
    const asked = addQty[l.salesOrderItem] ?? {
      rolls: row.leftRolls,
      looseBelts: row.leftBelts,
    };
    const rolls = Math.min(Math.max(0, asked.rolls), row.leftRolls);
    const belts = Math.min(Math.max(0, asked.looseBelts), row.leftBelts);
    if (rolls <= 0 && belts <= 0) return;

    const existing = lines.find((x) => x.salesOrderItem === l.salesOrderItem);
    const nextLines = existing
      ? lines.map((x) =>
          x.salesOrderItem === l.salesOrderItem
            ? {
                ...x,
                plannedRolls: x.plannedRolls + rolls,
                plannedLooseBelts: x.plannedLooseBelts + belts,
              }
            : x,
        )
      : [
          ...lines,
          {
            salesOrder: l.salesOrder,
            salesOrderItem: l.salesOrderItem,
            itemCode: l.itemCode,
            itemName: l.itemName,
            route: l.route,
            customerName: l.customerName,
            plannedRolls: rolls,
            plannedLooseBelts: belts,
          },
        ];
    setLines(nextLines);
    // The input has done its job; leave it showing what is left next time.
    setAddQty((prev) => {
      const next = { ...prev };
      delete next[l.salesOrderItem];
      return next;
    });
    void persist({ lines: nextLines });
  };

  const removeLine = (salesOrderItem: string) => {
    const nextLines = lines.filter((l) => l.salesOrderItem !== salesOrderItem);
    setLines(nextLines);
    if (draftId) void persist({ lines: nextLines });
  };

  /**
   * Send the dispatch. What was planned IS what goes.
   *
   * There was a second screen here that re-asked, line by line, how much
   * actually left, with a reason for any shortfall. It was asking a question
   * already answered: the quantity is chosen with the stepper when the line
   * is added, and shown in the table above before anything is clicked. A
   * partial load is planned as a partial load — 7 of 10 — and the other 3
   * stay on the order as Left, ready for the next van. Nothing is lost by
   * dropping the second pass; it only made the planner say the same number
   * twice.
   */
  const dispatchNow = async () => {
    if (!draftId || !user || !lines.length) return;
    setDispatching(true);
    setError(null);
    try {
      await Api.production.finalizeDispatch({
        id: draftId,
        user,
        lines: lines.map((l) => ({
          salesOrder: l.salesOrder,
          salesOrderItem: l.salesOrderItem,
          itemCode: l.itemCode,
          // Planned is dispatched. A shortfall against the ORDER is simply
          // the quantity still outstanding, which the ready list already
          // reports as Left — it is not an exception needing a reason.
          dispatchedRolls: l.plannedRolls,
          dispatchedLooseBelts: l.plannedLooseBelts,
        })),
      });
      setDone(`${vehicle || 'The vehicle'} dispatched — ${lines.length} line(s) sent.`);
      // Closed, not reopened: the van has gone, and the next one is a
      // deliberate act rather than something the screen assumes.
      closePanel();
      setTick((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not dispatch.');
    } finally {
      setDispatching(false);
    }
  };

  if (!user) return null;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Dispatch planning</div>
          <div className="page-head__sub">
            Bundle ready order lines onto one vehicle and date — what is left to send, and who
            it is going to
          </div>
        </div>
        <div className="cal__nav">
          {unit && <span className="small dim">{unit}</span>}
          <RefreshButton onClick={() => setTick((t) => t + 1)} loading={loading} />
        </div>
      </div>

      {error && (
        <Alert tone="danger" title="Could not read or save">
          {error}
        </Alert>
      )}
      {done && !error && (
        <div style={{ marginBottom: 14 }}>
          <Alert tone="ok" title={done} />
        </div>
      )}

      <div style={{ marginBottom: 14 }}>
      <Card title={draftOpen ? 'This dispatch' : 'No dispatch open'}>
        {!draftOpen ? (
          <div className="prod__actions">
            <Button variant="primary" onClick={startNew}>
              🚚 Start a new dispatch
            </Button>
            <span className="note">Or pick up an unfinished one from the tab below.</span>
          </div>
        ) : (
          <>
            <div className="prod__actions" style={{ marginBottom: 10 }}>
              <Field label="Vehicle">
                <Input
                  value={vehicle}
                  onChange={(e) => setVehicle(e.target.value)}
                  onBlur={() => void persist({ vehicle })}
                  placeholder="Vehicle number"
                />
              </Field>
              <Field label="Dispatch date">
                <Input
                  type="date"
                  value={dispatchDate}
                  onChange={(e) => setDispatchDate(e.target.value)}
                  onBlur={() => void persist({ dispatchDate })}
                />
              </Field>
              {saving && <span className="tiny dim">Saving…</span>}
            </div>

            {lines.length === 0 ? (
              <Empty icon="🚚" title="Nothing added yet">
                Add lines from the Ready to add tab below.
              </Empty>
            ) : (
              <div className="table-wrap">
                <table className="table">
                  <thead>
                    <tr>
                      <th>Customer</th>
                      <th>Route</th>
                      <th>Order</th>
                      <th>Item</th>
                      <th className="right">Planned</th>
                      <th />
                    </tr>
                  </thead>
                  <tbody>
                    {lines.map((l) => (
                      <tr key={l.salesOrderItem}>
                        <td className="small strong">{l.customerName}</td>
                        <td className="small">{l.route}</td>
                        <td className="mono small">{l.salesOrder}</td>
                        <td className="small">{l.itemName}</td>
                        <td className="right num">
                          {qtyText(l.plannedRolls, l.plannedLooseBelts)}
                        </td>
                        <td className="right">
                          <Button size="sm" variant="ghost" onClick={() => removeLine(l.salesOrderItem)}>
                            Remove
                          </Button>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}

            <div className="prod__actions" style={{ marginTop: 10 }}>
              <Button
                variant="primary"
                loading={dispatching}
                disabled={!draftId || lines.length === 0 || !vehicle || !dispatchDate}
                onClick={() => void dispatchNow()}
                title={
                  !vehicle || !dispatchDate
                    ? 'Set a vehicle and date first'
                    : 'Send these lines on this vehicle'
                }
              >
                Dispatch
              </Button>
              <Button variant="danger" disabled={saving} onClick={() => void cancelDispatch()}>
                Cancel this dispatch
              </Button>
            </div>
          </>
        )}
      </Card>
      </div>

      <Card flush>
        <div style={{ padding: '0 14px' }}>
          <Tabs tabs={tabs} active={view} onChange={setView} />
        </div>

        {loading && <Empty icon="◔" title="Reading…" />}

        {!loading && view === 'ready' && (
          readyByOrder.length === 0 ? (
            <Empty icon="✓" title="Nothing ready to add">
              {/*
                Says which of the reasons it is. "Nothing ready" on its own
                sent people looking for a broken screen when the real answer
                was that no line had reached Packed yet.
              */}
              {readyLines.length === 0
                ? 'No order line has reached Ready yet — a line becomes dispatchable once production packs it.'
                : 'Every ready line is already staged, either on this dispatch or on an unfinished one.'}
            </Empty>
          ) : (
            <div style={{ padding: '10px 14px' }}>
              {readyByOrder.map(([orderId, g], groupIndex) => {
                const done = g.rows.every((r) => r.full);
                return (
                <div
                  key={orderId}
                  /*
                   * A rule between orders. Two orders' tables sat flush
                   * against one another and read as one long list, so a line
                   * belonging to the next customer down looked like part of
                   * the order above it — which is how something gets loaded
                   * onto the wrong van. None above the first: a line at the
                   * top of a list separates it from nothing.
                   */
                  style={
                    groupIndex === 0
                      ? { marginBottom: 16 }
                      : {
                          marginBottom: 16,
                          borderTop: '1px solid var(--border)',
                          paddingTop: 16,
                        }
                  }
                >
                  {/*
                    One heading per order: who it is for, where it goes, who
                    sold it, and whether the whole thing is on the van yet.
                    The rep is here because the floor rings that person when a
                    line has to go short.
                  */}
                  <div className="row gap-2" style={{ alignItems: 'baseline', marginBottom: 6 }}>
                    <span className="strong">{g.head.customerName}</span>
                    <span className="mono tiny dim">{orderId}</span>
                    {done && <Badge tone="ok">fully added</Badge>}
                  </div>
                  <div className="tiny dim" style={{ marginBottom: 6 }}>
                    {g.head.route}
                    {g.head.rep ? ` · sold by ${g.head.rep}` : ''}
                  </div>

                  <div className="table-wrap">
                    <table className="table">
                      <thead>
                        <tr>
                          <th>Item</th>
                          <th className="right">Ready</th>
                          <th className="right">Added</th>
                          <th className="right">Left</th>
                          <th className="right">Add</th>
                          <th />
                        </tr>
                      </thead>
                      <tbody>
                        {g.rows.map((r) => {
                          const l = r.line;
                          const q = addQty[l.salesOrderItem] ?? {
                            rolls: r.leftRolls,
                            looseBelts: r.leftBelts,
                          };
                          return (
                            <tr key={l.salesOrderItem}>
                              <td className="small">{l.itemName}</td>
                              <td className="right num dim">
                                {qtyText(l.remainingRolls, l.remainingLooseBelts)}
                              </td>
                              <td className="right num">
                                {r.addedRolls > 0 || r.addedBelts > 0 ? (
                                  <b>{qtyText(r.addedRolls, r.addedBelts)}</b>
                                ) : (
                                  <span className="dim">—</span>
                                )}
                              </td>
                              {/*
                                The whole point of the row staying visible.
                                Add 3 of 10 and the other 7 are still owed —
                                before this, the line vanished and took the
                                shortfall with it.
                              */}
                              <td className="right num">
                                {r.full ? (
                                  <span className="dim">none</span>
                                ) : (
                                  <b style={{ color: 'var(--warn, #b26a00)' }}>
                                    {qtyText(r.leftRolls, r.leftBelts)}
                                  </b>
                                )}
                              </td>
                              {/*
                                Nudged, not typed. A planner works against
                                what is left — one more, one fewer — and the
                                buttons clamp to it, so the quantity cannot
                                be pushed past what the order still owes.
                                Belts get their own stepper only when the
                                line actually has some; on CTR and bonding
                                gum the counter is permanently zero and a
                                second control would be noise.
                              */}
                              <td className="right">
                                <div
                                  className="row gap-2"
                                  style={{ justifyContent: 'flex-end' }}
                                >
                                  <Stepper
                                    value={r.full ? 0 : q.rolls}
                                    min={0}
                                    max={r.leftRolls}
                                    disabled={r.full}
                                    ariaLabel={`rolls to add for ${l.itemName}`}
                                    onChange={(rolls) =>
                                      setAddQty((prev) => ({
                                        ...prev,
                                        [l.salesOrderItem]: { ...q, rolls },
                                      }))
                                    }
                                  />
                                  {r.leftBelts > 0 && (
                                    <Stepper
                                      value={r.full ? 0 : q.looseBelts}
                                      min={0}
                                      max={r.leftBelts}
                                      disabled={r.full}
                                      ariaLabel={`belts to add for ${l.itemName}`}
                                      onChange={(looseBelts) =>
                                        setAddQty((prev) => ({
                                          ...prev,
                                          [l.salesOrderItem]: { ...q, looseBelts },
                                        }))
                                      }
                                    />
                                  )}
                                </div>
                              </td>
                              <td className="right">
                                <Button
                                  size="sm"
                                  disabled={!draftOpen || r.full}
                                  title={
                                    !draftOpen
                                      ? 'Start a dispatch first'
                                      : r.full
                                        ? 'All of this line is already on the dispatch'
                                        : undefined
                                  }
                                  onClick={() => addLine(r)}
                                >
                                  Add
                                </Button>
                              </td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  </div>
                </div>
                );
              })}
            </div>
          )
        )}

        {!loading && view === 'drafts' && (
          drafts.length === 0 ? (
            <Empty icon="🗂" title="Nothing unfinished">
              Every dispatch has either gone out or been cancelled.
            </Empty>
          ) : (
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr>
                    <th>Vehicle</th>
                    <th>Date</th>
                    <th className="right">Lines</th>
                    <th />
                  </tr>
                </thead>
                <tbody>
                  {drafts.map((d) => (
                    <tr key={d.id}>
                      <td className="small">{d.vehicle || <span className="dim">not set</span>}</td>
                      <td className="small">{d.dispatchDate || <span className="dim">not set</span>}</td>
                      <td className="right num">{d.lines.length}</td>
                      <td className="right">
                        <Button
                          size="sm"
                          variant={draftId === d.id ? 'primary' : undefined}
                          onClick={() => resume(d)}
                        >
                          {draftId === d.id ? 'Editing' : 'Resume'}
                        </Button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )
        )}
      </Card>

    </div>
  );
}
