/**
 * The Managing Director's rates screen: reading SAP's prices (as copied into
 * ERPNext), and the dealer rules.
 *
 * Nothing here writes to SAP. Frappe Cloud has no route to the SAP LAN, and SAP
 * prices change only by DTW files the screen hands the MD. Two ERPNext records:
 *
 *   SAP Pricing Control   a Single. `sync_requested` is the flag the office
 *                         watcher reads every 15 seconds; `snapshot_json` is
 *                         what Sync-SapPricingSnapshot.ps1 last read from SAP
 *                         (Manna Treads, and Hi-Tech Pretreads' twins);
 *                         `intercompany_margin` is how many rupees per kg
 *                         Hi-Tech bills Manna Treads below Manna Treads' price.
 *                         The margin lives here and not in the code because
 *                         the code is public.
 *   SAP Dealer Rate Rule  one row per Manna Treads dealer × quality: rupees
 *                         off per kg.
 *
 * Both are readable and writable by the Higher Management role only (plus
 * System Manager, and the sync bot for the Single).
 */

import { createDoc, deleteDoc, getDoc, http, listDocs, updateDoc } from './client';
import type { DealerRule, PricingSnapshot } from '@/domain/dealerRates';

const CONTROL = 'SAP Pricing Control';
const RULE = 'SAP Dealer Rate Rule';

export interface PricingControl {
  status: 'Idle' | 'Running' | 'Success' | 'Failed' | string;
  syncRequested: boolean;
  requestedBy: string | null;
  requestedAt: string | null;
  lastRunStartedAt: string | null;
  lastSyncAt: string | null;
  lastResultMessage: string;
  cooldownUntil: string | null;
  /** Rupees per kg Hi-Tech's price is kept below Manna Treads'; null when not set. */
  margin: number | null;
  snapshot: PricingSnapshot | null;
  /** Why the snapshot could not be read, when it exists but will not parse. */
  snapshotError: string | null;
}

/**
 * The snapshot as stored. Version 2 (25 Sep 2026) keeps dealer prices as rows
 * under `specialCols` — 50 dealers on 1,800 items is 90,000 prices, 11 MB as
 * objects — and they are expanded here. Version 1 carried `special` objects.
 * Version 3 (the same day) is Manna Treads', with `hitech` and `serverCheck`
 * beside it; they pass through as they are.
 */
type RawSnapshot = Omit<PricingSnapshot, 'special'> & {
  special?: PricingSnapshot['special'];
  specialCols?: string[];
  specialRows?: unknown[][];
};

export function expandSnapshot(raw: RawSnapshot): PricingSnapshot {
  if (!raw.specialRows) return { ...raw, special: raw.special ?? [] };
  const cols = raw.specialCols ?? ['card', 'item', 'price', 'priceList', 'autoUpdate', 'discount', 'valid', 'currency'];
  const at = (name: string) => cols.indexOf(name);
  const [c, i, p, l, a, d, v, cur] = ['card', 'item', 'price', 'priceList', 'autoUpdate', 'discount', 'valid', 'currency'].map(at);
  const special = raw.specialRows.map((r) => ({
    card: String(r[c] ?? ''),
    item: String(r[i] ?? ''),
    price: Number(r[p] ?? 0),
    priceList: Number(r[l] ?? 0),
    autoUpdate: Number(r[a] ?? 0) === 1,
    discount: Number(r[d] ?? 0),
    valid: v < 0 ? true : Number(r[v] ?? 1) === 1,
    currency: cur < 0 ? 'INR' : String(r[cur] ?? 'INR'),
  }));
  const { specialCols: _cols, specialRows: _rows, ...rest } = raw;
  return { ...rest, special };
}

const s = (v: unknown): string | null => {
  const t = v == null ? '' : String(v).trim();
  return t && t !== 'null' ? t : null;
};

export async function getPricingControl(): Promise<PricingControl> {
  const d = await getDoc<Record<string, unknown>>(CONTROL, CONTROL);
  let snapshot: PricingSnapshot | null = null;
  let snapshotError: string | null = null;
  const raw = s(d.snapshot_json);
  if (raw) {
    try {
      snapshot = expandSnapshot(JSON.parse(raw) as RawSnapshot);
    } catch (e) {
      snapshotError = e instanceof Error ? e.message : 'unreadable';
    }
  }
  return {
    status: s(d.status) ?? 'Idle',
    syncRequested: Number(d.sync_requested ?? 0) === 1,
    requestedBy: s(d.sync_requested_by),
    requestedAt: s(d.sync_requested_at),
    lastRunStartedAt: s(d.last_run_started_at),
    lastSyncAt: s(d.last_sync_at),
    lastResultMessage: s(d.last_result_message) ?? '',
    cooldownUntil: s(d.cooldown_until),
    margin: Number(d.intercompany_margin ?? 0) > 0 ? Number(d.intercompany_margin) : null,
    snapshot,
    snapshotError,
  };
}

/** Raise the flag; the office server reads SAP and writes a fresh snapshot. */
export async function requestPricingSync(): Promise<{ message: string; afterCooldown: boolean }> {
  const { data } = await http.post<{ message: Record<string, unknown> }>('/api/method/manna_pricing_request_sync');
  const m = data.message ?? {};
  return { message: String(m.message ?? 'Requested.'), afterCooldown: Number(m.after_cooldown ?? 0) === 1 };
}

export async function listDealerRules(): Promise<DealerRule[]> {
  const rows = await listDocs<Record<string, unknown>>(RULE, {
    fields: ['name', 'card_code', 'card_name', 'property_no', 'quality', 'rupees_off', 'note'],
    orderBy: 'card_code asc, property_no asc',
    limit: 0,
  });
  return rows.map((r) => ({
    id: String(r.name),
    cardCode: String(r.card_code ?? ''),
    cardName: String(r.card_name ?? ''),
    propertyNo: Number(r.property_no ?? 0),
    quality: String(r.quality ?? ''),
    rupeesOff: Number(r.rupees_off ?? 0),
    note: s(r.note) ?? undefined,
  }));
}

function ruleBody(r: DealerRule): Record<string, unknown> {
  return {
    card_code: r.cardCode,
    card_name: r.cardName,
    property_no: r.propertyNo,
    quality: r.quality,
    rupees_off: r.rupeesOff,
    note: r.note ?? '',
  };
}

/** Apply a rule diff. Sequential, so a failure part-way names what was done. */
export async function saveDealerRules(diff: { create: DealerRule[]; update: DealerRule[]; remove: DealerRule[] }): Promise<void> {
  for (const r of diff.remove) if (r.id) await deleteDoc(RULE, r.id);
  for (const r of diff.update) if (r.id) await updateDoc(RULE, r.id, ruleBody(r));
  for (const r of diff.create) await createDoc(RULE, ruleBody(r));
}
