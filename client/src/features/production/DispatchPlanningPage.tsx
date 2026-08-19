/**
 * Dispatch Planning — the production manager's replacement for hand-picking
 * "Dispatched" off a line's stage dropdown.
 *
 * A dispatch bundles any number of lines from any number of Ready orders
 * onto one vehicle and one date. It stays a Draft — freely editable, saved to
 * ERPNext on every change so it survives a refresh — until the manager clicks
 * "Dispatch" and confirms what actually left, which may be less than what was
 * planned. That gap, plus a reason, is what shows up on the order afterwards.
 *
 * Route only, never the customer — the same rule every other production
 * screen in this module enforces.
 */

import { useEffect, useMemo, useState } from 'react';
import type { Dispatch, DispatchableLine } from '@/domain/types';
import { Api } from '@/api/client';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import {
  Alert,
  Button,
  Card,
  Empty,
  Field,
  Input,
  Modal,
  Tabs,
  Textarea,
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

/** One line in the finalize modal — planned, and what actually went. */
interface FinalizeLine extends DraftLine {
  dispatchedRolls: number;
  dispatchedLooseBelts: number;
  shortfallReason: string;
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

  const [finalizing, setFinalizing] = useState<FinalizeLine[] | null>(null);
  const [finalizeBusy, setFinalizeBusy] = useState(false);

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

  // Lines already staged in the open draft never show up again as "ready to add".
  const stagedKeys = useMemo(() => new Set(lines.map((l) => l.salesOrderItem)), [lines]);

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

  const readyByRoute = useMemo(() => {
    const groups = new Map<string, DispatchableLine[]>();
    for (const l of readyLines) {
      if (stagedKeys.has(l.salesOrderItem)) continue;
      if (stagedElsewhere.has(l.salesOrderItem)) continue;
      const bucket = groups.get(l.route) ?? [];
      bucket.push(l);
      groups.set(l.route, bucket);
    }
    return [...groups.entries()].sort(([a], [b]) => a.localeCompare(b));
  }, [readyLines, stagedKeys, stagedElsewhere]);

  /** How many lines the Ready tab is actually offering. */
  const readyCount = useMemo(
    () => readyByRoute.reduce((n, [, rows]) => n + rows.length, 0),
    [readyByRoute],
  );

  const tabs: TabDef<View>[] = [
    // Counted off the list actually rendered, not `readyLines - lines`, which
    // double-subtracted anything staged in another draft.
    { id: 'ready', label: `Ready to add (${readyCount})` },
    { id: 'drafts', label: `Draft dispatches (${drafts.length})` },
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

  /** Put the panel away. The draft itself is already saved in ERPNext. */
  const closeDraft = () => {
    setDraftOpen(false);
    setDraftId(null);
    setVehicle('');
    setDispatchDate('');
    setLines([]);
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

  const addLine = (l: DispatchableLine) => {
    const qty = addQty[l.salesOrderItem] ?? { rolls: l.remainingRolls, looseBelts: l.remainingLooseBelts };
    const nextLines = [
      ...lines,
      {
        salesOrder: l.salesOrder,
        salesOrderItem: l.salesOrderItem,
        itemCode: l.itemCode,
        itemName: l.itemName,
        route: l.route,
        customerName: l.customerName,
        plannedRolls: qty.rolls,
        plannedLooseBelts: qty.looseBelts,
      },
    ];
    setLines(nextLines);
    void persist({ lines: nextLines });
  };

  const removeLine = (salesOrderItem: string) => {
    const nextLines = lines.filter((l) => l.salesOrderItem !== salesOrderItem);
    setLines(nextLines);
    if (draftId) void persist({ lines: nextLines });
  };

  const openFinalize = () => {
    setFinalizing(
      lines.map((l) => ({
        ...l,
        dispatchedRolls: l.plannedRolls,
        dispatchedLooseBelts: l.plannedLooseBelts,
        shortfallReason: '',
      })),
    );
  };

  const confirmFinalize = async () => {
    if (!finalizing || !draftId || !user) return;
    setFinalizeBusy(true);
    setError(null);
    try {
      await Api.production.finalizeDispatch({
        id: draftId,
        user,
        lines: finalizing.map((l) => ({
          salesOrder: l.salesOrder,
          salesOrderItem: l.salesOrderItem,
          itemCode: l.itemCode,
          dispatchedRolls: l.dispatchedRolls,
          dispatchedLooseBelts: l.dispatchedLooseBelts,
          shortfallReason:
            l.dispatchedRolls < l.plannedRolls || l.dispatchedLooseBelts < l.plannedLooseBelts
              ? l.shortfallReason
              : undefined,
        })),
      });
      setDone(`${vehicle || 'The vehicle'} dispatched — ${lines.length} line(s) sent.`);
      setFinalizing(null);
      // Closed, not reopened: the van has gone, and the next one is a
      // deliberate act rather than something the screen assumes.
      closeDraft();
      setTick((t) => t + 1);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not finalize the dispatch.');
    } finally {
      setFinalizeBusy(false);
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
            <span className="note">Or resume one from the Draft dispatches tab below.</span>
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
                          {l.plannedRolls > 0 ? `${l.plannedRolls} rolls` : ''}
                          {l.plannedRolls > 0 && l.plannedLooseBelts > 0 ? ' + ' : ''}
                          {l.plannedLooseBelts > 0 ? `${l.plannedLooseBelts} belts` : ''}
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
                disabled={!draftId || lines.length === 0 || !vehicle || !dispatchDate}
                onClick={openFinalize}
                title={
                  !vehicle || !dispatchDate
                    ? 'Set a vehicle and date first'
                    : 'Lock this dispatch and record what actually went'
                }
              >
                Dispatch
              </Button>
              <Button variant="ghost" onClick={closeDraft}>
                Close (stays saved as a draft)
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
          readyByRoute.length === 0 ? (
            <Empty icon="✓" title="Nothing ready to add">
              {/*
                Says which of the three reasons it is. "Nothing ready" on its
                own sent people looking for a broken screen when the real
                answer was that no line had reached Packed yet.
              */}
              {readyLines.length === 0
                ? 'No order line has reached Ready yet — a line becomes dispatchable once production packs it.'
                : 'Every ready line is already staged, either on this dispatch or on another draft.'}
            </Empty>
          ) : (
            <div style={{ padding: '10px 14px' }}>
              {readyByRoute.map(([route, rows]) => (
                <div key={route} style={{ marginBottom: 14 }}>
                  <div className="strong small" style={{ marginBottom: 6 }}>
                    {route}
                  </div>
                  <div className="table-wrap">
                    <table className="table">
                      <thead>
                        <tr>
                          <th>Customer</th>
                          <th>Order</th>
                          <th>Item</th>
                          <th className="right">Remaining</th>
                          <th className="right">Add</th>
                          <th />
                        </tr>
                      </thead>
                      <tbody>
                        {rows.map((l) => {
                          const q = addQty[l.salesOrderItem] ?? {
                            rolls: l.remainingRolls,
                            looseBelts: l.remainingLooseBelts,
                          };
                          return (
                            <tr key={l.salesOrderItem}>
                              <td className="small strong">{l.customerName}</td>
                              <td className="mono small">{l.salesOrder}</td>
                              <td className="small">{l.itemName}</td>
                              <td className="right num">
                                {l.remainingRolls > 0 ? `${l.remainingRolls} rolls` : ''}
                                {l.remainingRolls > 0 && l.remainingLooseBelts > 0 ? ' + ' : ''}
                                {l.remainingLooseBelts > 0 ? `${l.remainingLooseBelts} belts` : ''}
                              </td>
                              <td className="right">
                                <Input
                                  compact
                                  numeric
                                  type="number"
                                  min={0}
                                  max={l.remainingRolls}
                                  value={q.rolls}
                                  onChange={(e) =>
                                    setAddQty((prev) => ({
                                      ...prev,
                                      [l.salesOrderItem]: { ...q, rolls: Number(e.target.value) || 0 },
                                    }))
                                  }
                                  aria-label={`Rolls to add for ${l.itemName}`}
                                />
                              </td>
                              <td className="right">
                                <Button
                                  size="sm"
                                  disabled={!draftOpen}
                                  title={draftOpen ? undefined : 'Start a dispatch first'}
                                  onClick={() => addLine(l)}
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
              ))}
            </div>
          )
        )}

        {!loading && view === 'drafts' && (
          drafts.length === 0 ? (
            <Empty icon="🗂" title="No drafts yet" />
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

      {finalizing && (
        <Modal
          title="Confirm what actually went"
          width="wide"
          onClose={() => setFinalizing(null)}
          footer={
            <>
              <Button onClick={() => setFinalizing(null)}>Cancel</Button>
              <Button variant="primary" loading={finalizeBusy} onClick={() => void confirmFinalize()}>
                Dispatch
              </Button>
            </>
          }
        >
          <div className="stack gap-3">
            <Alert tone="info">
              Defaults to what was planned. Reduce a line if less actually went, and say why — that
              shows on the order for the rep and the sales manager.
            </Alert>
            {finalizing.map((l, i) => {
              const short = l.dispatchedRolls < l.plannedRolls || l.dispatchedLooseBelts < l.plannedLooseBelts;
              return (
                <Card
                  key={l.salesOrderItem}
                  title={`${l.itemName} — ${l.customerName} · ${l.route}`}
                >
                  <div className="prod__actions" style={{ marginBottom: short ? 8 : 0 }}>
                    <Field label={`Dispatched rolls (of ${l.plannedRolls})`}>
                      <Input
                        numeric
                        compact
                        type="number"
                        min={0}
                        max={l.plannedRolls}
                        value={l.dispatchedRolls}
                        onChange={(e) => {
                          const v = Math.min(l.plannedRolls, Math.max(0, Number(e.target.value) || 0));
                          setFinalizing((prev) =>
                            prev!.map((row, j) => (j === i ? { ...row, dispatchedRolls: v } : row)),
                          );
                        }}
                      />
                    </Field>
                    {l.plannedLooseBelts > 0 && (
                      <Field label={`Dispatched belts (of ${l.plannedLooseBelts})`}>
                        <Input
                          numeric
                          compact
                          type="number"
                          min={0}
                          max={l.plannedLooseBelts}
                          value={l.dispatchedLooseBelts}
                          onChange={(e) => {
                            const v = Math.min(
                              l.plannedLooseBelts,
                              Math.max(0, Number(e.target.value) || 0),
                            );
                            setFinalizing((prev) =>
                              prev!.map((row, j) => (j === i ? { ...row, dispatchedLooseBelts: v } : row)),
                            );
                          }}
                        />
                      </Field>
                    )}
                  </div>
                  {short && (
                    <Field label="Reason for the shortfall">
                      <Textarea
                        value={l.shortfallReason}
                        onChange={(e) =>
                          setFinalizing((prev) =>
                            prev!.map((row, j) =>
                              j === i ? { ...row, shortfallReason: e.target.value } : row,
                            ),
                          )
                        }
                        placeholder="e.g. held back for weight"
                      />
                    </Field>
                  )}
                </Card>
              );
            })}
          </div>
        </Modal>
      )}
    </div>
  );
}
