/**
 * Which syncs a login's Sync button asks for — decided 25 September 2026.
 * Until then only Manna Treads sales logins could refresh stock and credit,
 * so the GM approved on credit figures nobody he could ask had refreshed.
 */

import { describe, expect, it } from 'vitest';
import { syncStamp, syncsFor, syncSummary } from '../syncScope';

describe('who refreshes what', () => {
  it('a Manna Treads sales manager refreshes everything', () => {
    expect(syncsFor({ role: 'sales_manager', salesCompany: 'Manna Treads' })).toEqual([
      'orders',
      'stock',
      'credit',
    ]);
  });

  it('the GM refreshes everything — he approves on credit and stock and has no Sales Person', () => {
    expect(syncsFor({ role: 'general_manager' })).toEqual(['orders', 'stock', 'credit']);
  });

  it('a Treads production or stock manager refreshes orders and stock, not credit', () => {
    expect(syncsFor({ role: 'production_manager', productionUnit: 'Manna Treads' })).toEqual([
      'orders',
      'stock',
    ]);
    expect(syncsFor({ role: 'stock_manager' })).toEqual(['orders', 'stock']);
  });

  it("another unit's login refreshes orders only — Treads' shelf and book are not theirs", () => {
    expect(syncsFor({ role: 'sales_manager', salesCompany: 'Manna Tyre Retreads' })).toEqual(['orders']);
    expect(syncsFor({ role: 'production_manager', productionUnit: 'Manna Tyre Retreads' })).toEqual([
      'orders',
    ]);
  });

  it("a login's own Sales Person company outranks the unit it runs", () => {
    // Renjith: production manager AND the UAE sales team's manager.
    expect(
      syncsFor({ role: 'production_manager', salesCompany: 'Manna Tyres UAE', productionUnit: 'Manna Treads' }),
    ).toEqual(['orders']);
  });

  it('the accountant refreshes orders only — he has no unit, but reads no stock or credit', () => {
    expect(syncsFor({ role: 'accountant' })).toEqual(['orders']);
    expect(syncsFor({ role: 'accountant', salesCompany: 'Manna Treads' })).toEqual(['orders']);
  });

  it('nobody signed in asks for nothing', () => {
    expect(syncsFor(null)).toEqual([]);
  });
});

/*
 * What the header's Sync button says at rest (11 Oct 2026): the status and
 * the last sync time, so a manager can tell from the header how old SAP's
 * figures are without pressing anything.
 */
describe('the Sync button at rest', () => {
  const now = new Date(2026, 9, 11, 19, 5); // 11 Oct 2026, 19:05 local

  it('writes the time out, not "3 days ago"', () => {
    expect(syncStamp('2026-10-11 18:52:03.123456', now)).toBe('today 18:52');
    expect(syncStamp('2026-10-10 09:05:00', now)).toBe('yesterday 09:05');
    expect(syncStamp('2026-09-27 14:52:00', now)).toBe('27 Sep 14:52');
    expect(syncStamp('2025-12-30 08:00:00', now)).toBe('30 Dec 2025 08:00');
    expect(syncStamp(null, now)).toBe('never');
  });

  it('shows the OLDEST good run, because one press syncs everything', () => {
    const s = syncSummary(
      [
        { kind: 'orders', status: 'Success', lastSyncAt: '2026-10-11 18:52:00' },
        { kind: 'stock', status: 'Success', lastSyncAt: '2026-09-26 07:44:00' },
      ],
      now,
    );
    expect(s).toMatchObject({ tone: 'ok', text: 'Synced 26 Sep 07:44' });
    expect(s!.detail).toBe('Orders: synced today 18:52\nStock: synced 26 Sep 07:44');
  });

  it('names a sync whose last run failed, with when it last worked', () => {
    const s = syncSummary(
      [
        { kind: 'orders', status: 'Failed', lastSyncAt: '2026-09-27 14:52:00' },
        { kind: 'stock', status: 'Success', lastSyncAt: '2026-10-11 18:00:00' },
      ],
      now,
    );
    expect(s).toMatchObject({ tone: 'warn', text: 'Orders sync failed · last good 27 Sep 14:52' });
    expect(s!.detail).toContain('Orders: synced 27 Sep 14:52 · last run failed');
  });

  it('says a run is under way first — someone else may have pressed', () => {
    const s = syncSummary(
      [
        { kind: 'orders', status: 'Failed', queued: true, lastSyncAt: '2026-09-27 14:52:00' },
        { kind: 'stock', status: 'Running', lastSyncAt: '2026-10-11 18:00:00' },
      ],
      now,
    );
    expect(s).toMatchObject({ tone: 'busy', text: 'Syncing orders and stock…' });
  });

  it('a sync that has never run counts as the oldest', () => {
    const s = syncSummary(
      [
        { kind: 'orders', status: 'Success', lastSyncAt: '2026-10-11 18:52:00' },
        { kind: 'credit', status: 'Idle', lastSyncAt: null },
      ],
      now,
    );
    expect(s!.text).toBe('Not synced yet');
  });

  it('says nothing for a login with no syncs', () => {
    expect(syncSummary([], now)).toBeNull();
  });
});
