/**
 * Who is shown an item's stock, and in what unit.
 *
 * Decided 24 September 2026: an item with both weight UDFs reads as rolls and
 * belts to everyone; an item missing either reads in kilograms to a sales
 * manager and is not shown to anyone else. See `domain/stockView.ts`.
 */

import { describe, expect, it } from 'vitest';
import { describeReading, hasStock, stockReading } from '../stockView';
import type { MinStockLine } from '../types';

const weighed = (over: Partial<MinStockLine> = {}): MinStockLine => ({
  itemCode: 'I-11672',
  itemName: 'Tread Rubber Precured Black Pearl 156 AJAX 91',
  kg: 149.2,
  uom: 'Kg',
  availableRolls: 3,
  availableBelts: 5,
  beltsPerRoll: 6,
  weightsKnown: true,
  ...over,
});

const unweighed = (over: Partial<MinStockLine> = {}): MinStockLine =>
  weighed({ itemCode: 'I-10280', kg: 91.5, availableRolls: 0, availableBelts: 0, beltsPerRoll: 0, weightsKnown: false, ...over });

describe('an item with both weights', () => {
  it('reads as rolls and belts to every role', () => {
    for (const role of ['sales_manager', 'stock_manager', 'production_manager', 'general_manager'] as const) {
      expect(stockReading(weighed(), role)).toEqual({ kind: 'rolls', rolls: 3, belts: 5 });
    }
  });

  it('is never shown in kilograms, even to a sales manager', () => {
    // The kilos are exact and the rolls are floored, so both on one row would
    // disagree — and the rolls are the figure that can be promised.
    expect(stockReading(weighed(), 'sales_manager')?.kind).toBe('rolls');
  });
});

describe('an item missing either weight', () => {
  it('is shown to a sales manager, in kilograms', () => {
    expect(stockReading(unweighed(), 'sales_manager')).toEqual({ kind: 'weight', qty: 91.5, uom: 'kg' });
  });

  it('is not shown to anyone else at all', () => {
    for (const role of ['stock_manager', 'production_manager', 'general_manager', 'hr', undefined] as const) {
      expect(stockReading(unweighed(), role)).toBeNull();
    }
  });

  it('reads in its own unit when it is not sold by weight', () => {
    expect(stockReading(unweighed({ uom: 'Nos', kg: 12 }), 'sales_manager')).toEqual({
      kind: 'weight',
      qty: 12,
      uom: 'Nos',
    });
  });

  it('never reads negative when SAP has committed more than it holds', () => {
    const r = stockReading(unweighed({ kg: -12.5 }), 'sales_manager');
    expect(r).toEqual({ kind: 'weight', qty: 0, uom: 'kg' });
    expect(hasStock(r!)).toBe(false);
  });

  it('still carries a quantity nobody else may read — the kilos stay on the line, not the view', () => {
    // The row keeps its kilos for the manager; what stops a rep seeing them is
    // the reading, so no screen can route around it by rendering `kg` directly
    // without going through `stockReading`.
    expect(unweighed().kg).toBe(91.5);
    expect(stockReading(unweighed(), 'stock_manager')).toBeNull();
  });
});

describe('how a reading is written', () => {
  it('names rolls and belts, and only the ones there are', () => {
    expect(describeReading({ kind: 'rolls', rolls: 3, belts: 5 })).toBe('3 rolls + 5 belts');
    expect(describeReading({ kind: 'rolls', rolls: 1, belts: 0 })).toBe('1 roll');
    expect(describeReading({ kind: 'rolls', rolls: 0, belts: 7 })).toBe('7 belts');
    expect(describeReading({ kind: 'rolls', rolls: 0, belts: 0 })).toBe('none');
  });

  it('gives kilograms to two places', () => {
    expect(describeReading({ kind: 'weight', qty: 188.784, uom: 'kg' })).toBe('188.78 kg');
  });
});
