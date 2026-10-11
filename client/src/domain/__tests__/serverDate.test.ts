/**
 * Reading the sync scripts' datetimes, whichever way they were written.
 *
 * Found 24 September 2026: the stock and order status scripts send Python's
 * `str(datetime)`, which Safari cannot parse — every iPhone would have read
 * "never synced".
 */

import { describe, expect, it } from 'vitest';
import { agoText, parseServerDate } from '../serverDate';

describe('parseServerDate', () => {
  it("reads Python's str() form — a space and microseconds", () => {
    expect(parseServerDate('2026-09-24 17:43:08.249939')).toBe(
      new Date(2026, 8, 24, 17, 43, 8, 249).getTime(),
    );
  });

  it('reads isoformat() the same way', () => {
    expect(parseServerDate('2026-09-24T17:43:08')).toBe(new Date(2026, 8, 24, 17, 43, 8).getTime());
  });

  it('reads blank, null and junk as NaN rather than as a date', () => {
    expect(parseServerDate('')).toBeNaN();
    expect(parseServerDate(null)).toBeNaN();
    expect(parseServerDate('not a date')).toBeNaN();
  });
});

describe('agoText', () => {
  const now = new Date(2026, 8, 25, 12, 0, 0);

  it('says never when there is no time at all', () => {
    expect(agoText(null, now)).toBe('never');
  });

  it('counts minutes, hours and days, singular where it should be', () => {
    expect(agoText('2026-09-25 11:59:40', now)).toBe('just now');
    expect(agoText('2026-09-25 11:59:00', now)).toBe('1 minute ago');
    expect(agoText('2026-09-25 11:48:00', now)).toBe('12 minutes ago');
    expect(agoText('2026-09-25 09:00:00', now)).toBe('3 hours ago');
    expect(agoText('2026-09-24 17:43:08.249939', now)).toBe('18 hours ago');
    expect(agoText('2026-09-23 11:00:00', now)).toBe('2 days ago');
  });
});
