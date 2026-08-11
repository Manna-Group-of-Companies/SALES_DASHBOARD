/**
 * Per-category production process cycles (spec 3.2).
 *
 * PROVISIONAL. The real stage list is coming as a separate process document.
 * Everything downstream reads `STAGE_CYCLES` and nothing hard-codes a stage
 * name, so replacing the contents of this file is the whole migration — no
 * screen or reducer needs to change.
 */

import type { OrderItem, ProductCategory } from './types';

export interface ProcessStage {
  /** Stable key persisted on the order item. */
  key: string;
  label: string;
  /** Short hint shown to the floor under the stage name. */
  hint?: string;
  /** Marks the stage that means "done, ready to dispatch". */
  terminal?: boolean;
}

export const STAGE_CYCLES: Record<ProductCategory, ProcessStage[]> = {
  PCTR: [
    { key: 'queued', label: 'Queued', hint: 'Awaiting a production slot' },
    { key: 'mixing', label: 'Mixing', hint: 'Compound preparation' },
    { key: 'extrusion', label: 'Extrusion', hint: 'Tread profile extruded' },
    { key: 'curing', label: 'Curing / Moulding', hint: 'Press cycle' },
    { key: 'trimming', label: 'Trimming', hint: 'Belts cut to length' },
    { key: 'qc', label: 'Quality Check' },
    { key: 'packing', label: 'Packing', hint: 'Rolled and wrapped' },
    { key: 'ready', label: 'Ready for Dispatch', terminal: true },
  ],
  CTR: [
    { key: 'queued', label: 'Queued', hint: 'Awaiting a production slot' },
    { key: 'mixing', label: 'Mixing', hint: 'Compound preparation' },
    { key: 'calendering', label: 'Calendering', hint: 'Sheeted to gauge' },
    { key: 'cutting', label: 'Cutting', hint: 'Cut to fixed-weight rolls' },
    { key: 'qc', label: 'Quality Check' },
    { key: 'packing', label: 'Packing' },
    { key: 'ready', label: 'Ready for Dispatch', terminal: true },
  ],
  BG: [
    { key: 'queued', label: 'Queued' },
    { key: 'mixing', label: 'Mixing', hint: 'Gum compound' },
    { key: 'calendering', label: 'Calendering' },
    { key: 'rolling', label: 'Rolling', hint: '5 kg rolls' },
    { key: 'boxing', label: 'Boxing', hint: '4 rolls to a box' },
    { key: 'qc', label: 'Quality Check' },
    { key: 'ready', label: 'Ready for Dispatch', terminal: true },
  ],
  VS: [
    { key: 'queued', label: 'Queued' },
    { key: 'blending', label: 'Blending', hint: 'Solution mixed' },
    { key: 'filling', label: 'Filling', hint: '10L / 30L tins' },
    { key: 'sealing', label: 'Sealing' },
    { key: 'qc', label: 'Quality Check' },
    { key: 'packing', label: 'Packing' },
    { key: 'ready', label: 'Ready for Dispatch', terminal: true },
  ],
};

export function stagesFor(category: ProductCategory): ProcessStage[] {
  return STAGE_CYCLES[category];
}

export function firstStage(category: ProductCategory): string {
  return STAGE_CYCLES[category][0].key;
}

export function stageIndex(category: ProductCategory, key: string | undefined): number {
  if (!key) return 0;
  const i = STAGE_CYCLES[category].findIndex((s) => s.key === key);
  return i < 0 ? 0 : i;
}

export function stageLabel(category: ProductCategory, key: string | undefined): string {
  const stages = STAGE_CYCLES[category];
  return stages[stageIndex(category, key)]?.label ?? '—';
}

export function nextStage(category: ProductCategory, key: string | undefined): ProcessStage | null {
  const stages = STAGE_CYCLES[category];
  const i = stageIndex(category, key);
  return i + 1 < stages.length ? stages[i + 1] : null;
}

export function prevStage(category: ProductCategory, key: string | undefined): ProcessStage | null {
  const stages = STAGE_CYCLES[category];
  const i = stageIndex(category, key);
  return i > 0 ? stages[i - 1] : null;
}

export function isTerminalStage(category: ProductCategory, key: string | undefined): boolean {
  const stages = STAGE_CYCLES[category];
  return Boolean(stages[stageIndex(category, key)]?.terminal);
}

/** 0–1, for the per-item progress bar on the production board. */
export function stageProgress(category: ProductCategory, key: string | undefined): number {
  const stages = STAGE_CYCLES[category];
  if (stages.length <= 1) return 1;
  return stageIndex(category, key) / (stages.length - 1);
}

/** An order is dispatchable once every line has reached its terminal stage. */
export function allItemsReady(items: OrderItem[]): boolean {
  return items.length > 0 && items.every((it) => isTerminalStage(it.category, it.stage));
}

/** Overall order progress — the mean of its lines. */
export function orderProgress(items: OrderItem[]): number {
  if (!items.length) return 0;
  const sum = items.reduce((a, it) => a + stageProgress(it.category, it.stage), 0);
  return sum / items.length;
}
