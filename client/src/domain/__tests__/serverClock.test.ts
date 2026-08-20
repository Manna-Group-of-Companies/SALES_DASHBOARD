/**
 * The datetime format Frappe will actually accept.
 *
 * This exists because of a real failure on 20 Aug 2026: saving a dispatch
 * draft died with
 *
 *   (1292, "Incorrect datetime value: '2026-08-20T09:12:44.541Z'
 *    for column ... `tabManna Dispatch`.`created_on` at row 1")
 *
 * `toISOString()` is the natural thing to reach for and is always wrong here.
 * MariaDB rejects the `T` and the `Z`, and the whole document write fails —
 * not just that field.
 */

import { describe, expect, it } from 'vitest';
import { frappeNow, frappeToday } from '../serverClock';

/** What Frappe accepts, and nothing else: `YYYY-MM-DD HH:MM:SS`. */
const FRAPPE_DATETIME = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/;

describe('the stamp written to a Frappe Datetime field', () => {
  it('is YYYY-MM-DD HH:MM:SS', () => {
    expect(frappeNow()).toMatch(FRAPPE_DATETIME);
  });

  it('carries neither the T separator nor the Z suffix that broke the write', () => {
    const now = frappeNow();
    expect(now).not.toContain('T');
    expect(now).not.toContain('Z');
    // Milliseconds are just as unacceptable to MariaDB in this column.
    expect(now).not.toContain('.');
  });

  it('is the local wall clock, not UTC', () => {
    /*
     * Frappe stores naive datetimes in the site's own timezone, so a UTC
     * stamp reads as the wrong time by the offset — 5½ hours here, which
     * silently back-dates every dispatch raised before 05:30 IST.
     */
    const t = new Date();
    expect(frappeNow().slice(11, 13)).toBe(String(t.getHours()).padStart(2, '0'));
  });

  it('gives a date that matches the local day, not the UTC one', () => {
    // The trap this closes: `toISOString().slice(0, 10)` rolls over at
    // 05:30 IST, so an evening batch would be stocked under tomorrow's date.
    const t = new Date();
    const local = `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, '0')}-${String(
      t.getDate(),
    ).padStart(2, '0')}`;
    expect(frappeToday()).toBe(local);
  });

  it('pads every part, so the string is always the same length', () => {
    // An unpadded month or hour is a different format, and Frappe is strict.
    expect(frappeNow()).toHaveLength('YYYY-MM-DD HH:MM:SS'.length);
  });
});
