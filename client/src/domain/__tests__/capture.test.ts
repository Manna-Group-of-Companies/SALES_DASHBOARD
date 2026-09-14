/**
 * Where a place's location may be moved to, and by whom.
 *
 * Checked against `shared/fixtures/capture.json`, the same file
 * `app/test/capture_test.dart` reads. The verified pair is what every punch-in
 * on the phone measures against, and this dashboard is the easiest place to
 * write a wrong one — capture here uses the browser's position, and a
 * manager's browser is at the office.
 */

import { describe, expect, it } from 'vitest';
import fixture from '../../../../shared/fixtures/capture.json';
import { checkCapture, MAX_SELF_VERIFIED_MOVE_METRES } from '../capture';

describe('shared/fixtures/capture.json', () => {
  it('has cases to run', () => {
    expect(fixture.cases.length).toBeGreaterThan(0);
  });

  it('enforces the same limit the phone does', () => {
    // Stated in the fixture as well as in the code, so changing one side fails
    // the other side's build rather than passing quietly.
    expect(MAX_SELF_VERIFIED_MOVE_METRES).toBe(fixture.limit_metres);
  });

  for (const c of fixture.cases) {
    it(c.why, () => {
      const verdict = checkCapture({
        selfVerifying: c.self_verifying,
        latitude: c.captured.lat,
        longitude: c.captured.lng,
        existingLatitude: c.existing ? c.existing.lat : undefined,
        existingLongitude: c.existing ? c.existing.lng : undefined,
      });
      expect(verdict.allowed).toBe(c.expect_allowed);
    });
  }
});

describe('what the person refused is told', () => {
  it('names the distance, not just the refusal', () => {
    const v = checkCapture({
      selfVerifying: true,
      latitude: 9.19733,
      longitude: 76.5344,
      existingLatitude: 9.0544,
      existingLongitude: 76.5344,
    });
    expect(v.allowed).toBe(false);
    expect(v.message).toContain('km away');
    // The one thing the person at a desk can actually do about it.
    expect(v.message).toContain('rep');
  });
});
