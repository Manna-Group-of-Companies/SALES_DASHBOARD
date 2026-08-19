/**
 * Production stages, and rolling them up to the order.
 *
 * ⚠ **The stage sequences below are placeholders.** The real factory cycles
 * are still to come. They are held here as data — nothing downstream names a
 * stage — so replacing the contents of `SEQUENCES` is the whole migration.
 *
 * Two rules in here are not placeholders and must survive that replacement:
 *
 *   - **Where the goods come from outranks what they are made of.** A line
 *     served from minimum stock skips the making stages entirely, because the
 *     goods already exist on a shelf — that is the whole point of the pool.
 *   - **Errors round down.** An unrecognised stage counts as rank 0, never as
 *     finished. Rounding up would let a typo make an order look shippable.
 */

import { PRODUCTION_STATUS, type ProductionStatus } from './orderStatus';
import { FULFILMENT_MODE } from '@/api/endpoints';

export const NOT_STARTED = 'Not Started';
export const PACKED = 'Packed';
export const DISPATCHED = 'Dispatched';

/**
 * A line drawn from the pool is picked and sent, nothing more.
 *
 * Showing a stock line as "stage 3 of 8, Curing" describes work nobody is
 * doing, and leaves the floor looking permanently behind on orders that were
 * finished before they were placed.
 */
export const MINIMUM_STOCK_SEQUENCE = [NOT_STARTED, PACKED, DISPATCHED];

/** Keyed by the **order line's** category vocabulary (`PCTR`/`CTR`/`BG`/`VS`). */
export const SEQUENCES: Record<string, string[]> = {
  PCTR: [
    NOT_STARTED,
    'Compound Mixing',
    'Extrusion',
    'Curing',
    'Trimming',
    'Quality Check',
    PACKED,
    DISPATCHED,
  ],
  CTR: [
    NOT_STARTED,
    'Compound Mixing',
    'Calendering',
    'Cutting to Length',
    'Quality Check',
    PACKED,
    DISPATCHED,
  ],
  BG: [NOT_STARTED, 'Compound Mixing', 'Sheeting', 'Rolling', PACKED, DISPATCHED],
  VS: [NOT_STARTED, 'Blending', 'Filling', 'Sealing', PACKED, DISPATCHED],
};

/** Used when a line's category is missing or unrecognised. */
export const FALLBACK_SEQUENCE = [NOT_STARTED, 'In Production', PACKED, DISPATCHED];

/** What this line carries, as far as staging is concerned. */
export interface StagedLine {
  category?: string;
  fulfilmentMode?: string;
  /** Stage of the portion being **made**. */
  productionStage?: string;
  /** Stage of the portion coming **off the shelf**. */
  stockStage?: string;
  /** Rolls/belts reserved against a pool, from the reservation rows. */
  reservedRolls?: number;
  reservedBelts?: number;
  /** Rolls/belts that have to be manufactured. */
  toMakeRolls?: number;
  toMakeBelts?: number;
  /** False when the reservations could not be read — show one track, not two. */
  splitKnown?: boolean;
}

const has = (a?: number, b?: number) => (a ?? 0) > 0 || (b ?? 0) > 0;

/** Does this line have a portion coming off the shelf? */
export function hasStockHalf(line: StagedLine): boolean {
  return line.splitKnown !== false && has(line.reservedRolls, line.reservedBelts);
}

/** Does this line have a portion that must be manufactured? */
export function hasMakeHalf(line: StagedLine): boolean {
  if (line.splitKnown === false) return false;
  // A line with a reserved part and nothing left over is wholly off the shelf.
  if (hasStockHalf(line)) return has(line.toMakeRolls, line.toMakeBelts);
  return false;
}

/**
 * The stage list for one line, when it is shown as a single track.
 *
 * Fulfilment is checked first and deliberately: a line wholly pulled from the
 * pool is a three-step job, not an eight-step one, however it was made.
 */
export function sequenceFor(line: StagedLine): string[] {
  const mode = (line.fulfilmentMode ?? '').trim();
  if (mode === FULFILMENT_MODE.minimumStock) return MINIMUM_STOCK_SEQUENCE;
  return SEQUENCES[(line.category ?? '').trim()] ?? FALLBACK_SEQUENCE;
}

/**
 * The two tracks a split line is worked in.
 *
 * A split line is two pieces of work that finish separately: the shelf half
 * only has to be picked and packed, while the made half runs the family's full
 * cycle. Showing the shelf half against Curing and Extrusion described work
 * nobody was doing, and left the floor looking permanently behind on goods
 * that were finished before the order was placed.
 *
 * When the split is unknown — the reservation lookup failed — a single
 * `progress` track is returned instead. One honest track beats two invented
 * ones.
 */
export interface Track {
  key: 'stock' | 'make' | 'progress';
  title: string;
  sequence: string[];
  stage: string;
  /** Which field a change writes to. */
  field: 'stockStage' | 'productionStage';
}

const qtyLabel = (rolls?: number, belts?: number): string => {
  const parts: string[] = [];
  if ((rolls ?? 0) > 0) parts.push(String(rolls));
  if ((belts ?? 0) > 0) parts.push(`${belts} belts`);
  return parts.join(' + ') || '0';
};

export function tracksFor(line: StagedLine): Track[] {
  const stockHalf = hasStockHalf(line);
  const makeHalf = hasMakeHalf(line);

  if (!stockHalf) {
    // No reserved portion, or the split is unknown: one track, as before.
    return [
      {
        key: 'progress',
        title: 'Progress',
        sequence: sequenceFor(line),
        stage: (line.productionStage ?? '').trim() || NOT_STARTED,
        field: 'productionStage',
      },
    ];
  }

  const tracks: Track[] = [
    {
      key: 'stock',
      title: `From minimum stock · ${qtyLabel(line.reservedRolls, line.reservedBelts)}`,
      sequence: MINIMUM_STOCK_SEQUENCE,
      stage: (line.stockStage ?? '').trim() || NOT_STARTED,
      field: 'stockStage',
    },
  ];
  if (makeHalf) {
    tracks.push({
      key: 'make',
      title: `To be made · ${qtyLabel(line.toMakeRolls, line.toMakeBelts)}`,
      sequence: SEQUENCES[(line.category ?? '').trim()] ?? FALLBACK_SEQUENCE,
      stage: (line.productionStage ?? '').trim() || NOT_STARTED,
      field: 'productionStage',
    });
  }
  return tracks;
}

/** The stored stage, treating blank as the first step. */
export function currentStage(line: StagedLine): string {
  const s = (line.productionStage ?? '').trim();
  return s || NOT_STARTED;
}

/**
 * Where the stored stage sits in this line's sequence, or -1 when it is not in
 * it at all.
 *
 * -1 is returned rather than 0 so the caller can tell "not started" from
 * "impossible" and say so. That happens when the stage lists are revised under
 * a running order, and when a line is switched to minimum stock after the
 * floor has already started making it.
 */
export function stageIndex(line: StagedLine): number {
  return sequenceFor(line).indexOf(currentStage(line));
}

export function stageIsUnknown(line: StagedLine): boolean {
  return stageIndex(line) < 0;
}

/** 0–1 for the progress bar. An unknown stage shows no progress, never full. */
export function stageProgress(line: StagedLine): number {
  const seq = sequenceFor(line);
  const i = stageIndex(line);
  if (i < 0 || seq.length <= 1) return 0;
  return i / (seq.length - 1);
}

/** "Stage 3 of 8 · Curing", or the error when the stage is off-sequence. */
export function stageCaption(line: StagedLine): string {
  const seq = sequenceFor(line);
  const i = stageIndex(line);
  if (i < 0) return `Stage "${currentStage(line)}" is not in this product's cycle`;
  return `Stage ${i + 1} of ${seq.length} · ${seq[i]}`;
}

// ------------------------------------------- what the floor is shown ---
//
// Paired with `app/lib/core/production_stages.dart`. Both read
// `shared/fixtures/production_progress.json` in their tests.
//
// Dispatch Planning took `Dispatched` off the stage picker: the floor cannot
// reach that stage any more, it is written only once a line's full ordered
// quantity has actually gone out. Measuring the floor's own progress against
// it left a packed — i.e. finished — line reading "Stage 2 of 3" behind a
// half-empty bar, which says "you are behind" about work that is done.
//
// So the floor is shown its own stages: the sequence up to and including
// `Packed`. `Dispatched` stays in the stored sequence and `rollUp` still
// ranks it above `Packed` to decide the order's Ready/Dispatched status —
// that is deliberately untouched. This changes only what is displayed.

/** The stages the floor actually works — the sequence without `Dispatched`. */
export function workSequence(sequence: string[]): string[] {
  return sequence.filter((s) => s !== DISPATCHED);
}

/**
 * Where a stage sits among the floor's own stages, 1-based, or -1 when it is
 * off-sequence.
 *
 * `Dispatched` maps onto the last worked stage rather than past the end: the
 * goods are gone, so the floor's part is finished, and reporting it as a step
 * beyond the list would read as work somebody skipped.
 */
export function workPosition(sequence: string[], stage: string | undefined): number {
  const work = workSequence(sequence);
  const current = (stage ?? '').trim() || NOT_STARTED;
  if (current === DISPATCHED) return work.length;
  const i = work.indexOf(current);
  return i < 0 ? -1 : i + 1;
}

/** How many stages the floor works. The denominator in "step 7 of 7". */
export function workTotal(sequence: string[]): number {
  return workSequence(sequence).length;
}

/** 0–1 across the floor's own stages. Off-sequence shows none, never full. */
export function workProgress(sequence: string[], stage: string | undefined): number {
  const total = workTotal(sequence);
  const pos = workPosition(sequence, stage);
  if (pos < 0 || total <= 1) return 0;
  return (pos - 1) / (total - 1);
}

/** True once the floor has nothing left to do on this line. */
export function workComplete(sequence: string[], stage: string | undefined): boolean {
  const pos = workPosition(sequence, stage);
  return pos > 0 && pos === workTotal(sequence);
}

// ----------------------------------------------------------- the roll-up ---

/**
 * Rank a line for the roll-up. **Unrecognised is 0, never finished.**
 *
 * Ranks are coarse on purpose — the order-level Select only has four values,
 * so the fine stage name is irrelevant beyond which of these bands it falls
 * in.
 */
function rankIn(sequence: string[], stage: string | undefined): 0 | 1 | 2 | 3 {
  const current = (stage ?? '').trim() || NOT_STARTED;
  const i = sequence.indexOf(current);
  if (i < 0) return 0; // off-sequence: round down, always
  const at = sequence[i];
  if (at === DISPATCHED) return 3;
  if (at === PACKED) return 2;
  if (i === 0) return 0;
  return 1;
}

function rankOf(line: StagedLine): 0 | 1 | 2 | 3 {
  return rankIn(sequenceFor(line), currentStage(line));
}

/**
 * Every half of every line, as ranks.
 *
 * A split line contributes **two** ranks, because it is two pieces of work
 * that finish separately. Four rolls dispatched off the shelf while four are
 * still being made is not a finished order, and weighing only one half is
 * exactly how it would come to look like one.
 */
function ranksOf(line: StagedLine): (0 | 1 | 2 | 3)[] {
  if (!hasStockHalf(line)) return [rankOf(line)];
  const out: (0 | 1 | 2 | 3)[] = [rankIn(MINIMUM_STOCK_SEQUENCE, line.stockStage)];
  if (hasMakeHalf(line)) {
    const family = SEQUENCES[(line.category ?? '').trim()] ?? FALLBACK_SEQUENCE;
    out.push(rankIn(family, line.productionStage));
  }
  return out;
}

/**
 * The order-level status implied by its lines.
 *
 * Three things here are load-bearing:
 *
 *   - **Ready and Dispatched are decided by the slowest line.** An order is
 *     not ready because one line of four is packed.
 *   - **Started is decided by the fastest.** Once the floor has touched
 *     anything, work is under way.
 *   - The result is always one of the four values the Select accepts, so this
 *     is the only thing that may be written to `custom_production_status`.
 */
export function rollUp(lines: StagedLine[]): ProductionStatus {
  if (!lines.length) return PRODUCTION_STATUS.notStarted;
  const ranks = lines.flatMap(ranksOf);
  if (ranks.every((r) => r === 3)) return PRODUCTION_STATUS.dispatched;
  if (ranks.every((r) => r >= 2)) return PRODUCTION_STATUS.ready;
  if (ranks.some((r) => r > 0)) return PRODUCTION_STATUS.inProduction;
  return PRODUCTION_STATUS.notStarted;
}

/**
 * Whether a line has been dispatched — the first and strongest reason the
 * fulfilment toggle locks.
 */
export function lineDispatched(line: StagedLine): boolean {
  return currentStage(line) === DISPATCHED;
}
