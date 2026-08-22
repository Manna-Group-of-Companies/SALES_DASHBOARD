// Splitting an order line between the minimum-stock pool and production.
//
// WHY THIS EXISTS
//
// A rep ordered five rolls and one loose belt of a PCTR item on 21 August
// 2026. The pool held **48 rolls**. The app told them the five rolls would come
// from minimum stock and the one belt would be MADE TO ORDER.
//
// Rolls and belts were being clamped against the pool on separate axes — rolls
// against whole rolls, belts against loose belts only. A pool holding whole
// rolls and no loose belts therefore covered no belts at all, however much
// stock was on the shelf.
//
// **A belt comes out of a roll.** Serving one against a pool with no loose
// belts opens a whole roll: the belt goes out and the rest of that roll stays
// in the pool as loose stock. `MinStock.availableLooseBelts` has always added
// that remainder back, and `MinStock.beltCeiling` has always said the ceiling
// is every belt in the pool — the split was the one place that disagreed.
//
// The rule is pinned by `shared/fixtures/belt_from_roll.json`, which the
// dashboard's test suite reads too. Its implementation there is
// `allocateFromPool` in `client/src/domain/minimumStock.ts`. Change one and
// you must change the other and the fixture, in the same commit.

import 'dart:math' as math;

/// What one order can take off a pool, and what is left for production.
class PoolAllocation {
  /// Whole rolls served from the pool.
  final double rolls;

  /// Belts served, whether loose or cut from a roll opened for them.
  final int belts;

  /// Rolls broken into to cover [belts]. They leave the roll count; the belts
  /// not sold stay in the pool as loose stock.
  final int rollsOpened;

  /// What the pool could not cover. This, and only this, is production.
  final double shortRolls;
  final int shortBelts;

  const PoolAllocation({
    required this.rolls,
    required this.belts,
    required this.rollsOpened,
    required this.shortRolls,
    required this.shortBelts,
  });

  /// True when any part of the line has to be made.
  bool get splits => shortRolls > 0.0001 || shortBelts > 0;
}

double _clamp(double v) => v.isNaN || v < 0 ? 0 : v;
int _clampInt(int v) => v < 0 ? 0 : v;

/// Split a line between what the pool covers and what must be made.
///
/// Order of service, and why:
///
///  - **Loose belts before opening a roll.** A roll already cut should be
///    finished before another one is broken into.
///  - **Whole rolls before rolls opened for belts.** Only bites when the pool
///    cannot cover everything, and there it gives the customer more product —
///    a whole roll rather than one belt cut off it.
///  - **Nothing is cut when [beltsPerRoll] is 0 or less.** That means the item
///    is not sold in belts, or its master is incomplete. Either way selling
///    belts that cannot be cut is the worse mistake, so this rounds towards
///    refusing rather than towards promising.
PoolAllocation allocateFromPool({
  required double wantRolls,
  required int wantBelts,
  required double poolRolls,
  required int poolBelts,
  required int beltsPerRoll,
}) {
  final want = _clamp(wantRolls);
  final wantB = _clampInt(wantBelts);
  final pool = _clamp(poolRolls);
  final poolB = _clampInt(poolBelts);
  final perRoll = _clampInt(beltsPerRoll);

  final rolls = math.min(want, pool);

  final fromLoose = math.min(wantB, poolB);
  var stillWanted = wantB - fromLoose;

  var rollsOpened = 0;
  var fromOpened = 0;
  if (stillWanted > 0 && perRoll > 0) {
    // Whole rolls only: half a roll cannot be opened, and what is left after
    // the whole rolls promised above is all there is to cut into.
    final spare = (pool - rolls).floor();
    rollsOpened = math.min((stillWanted / perRoll).ceil(), math.max(0, spare));
    fromOpened = math.min(stillWanted, rollsOpened * perRoll);
    stillWanted -= fromOpened;
  }

  final belts = fromLoose + fromOpened;
  return PoolAllocation(
    rolls: rolls,
    belts: belts,
    rollsOpened: rollsOpened,
    shortRolls: want - rolls,
    shortBelts: wantB - belts,
  );
}
