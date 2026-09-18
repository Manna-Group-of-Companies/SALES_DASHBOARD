/**
 * One product line on the order form.
 *
 * The whole of spec 1.2–1.5 is visible here: which fields a category offers,
 * what it shows read-only, and how quantity is derived.
 *
 *   PCTR — shows avg weight/roll and belts/roll; rep keys rolls + loose belts.
 *   CTR  — exact weight/roll; rep keys rolls only, weight is derived.
 *   BG   — kg only, snapped to 5 kg steps, with box/roll breakdown.
 *   VS   — tins of a fixed 10L or 30L size, priced per tin.
 */

import { memo } from 'react';
import type { MinStockLine, Product } from '@/domain/types';
import {
  BG_KG_PER_BOX,
  BG_KG_PER_ROLL,
  computeLine,
  rateUnitFor,
  snapBgKg,
  validateLine,
  beltWeight,
  isMisconfigured,
  rollWeight,
  type LineInput,
} from '@/domain/productRules';
import { shelfAvailable } from '@/domain/minimumStock';
import { Field, Input, UnitInput } from '@/components/ui';
import { money } from '@/components/common/format';
import { StockChip } from '@/features/stock/StockChip';

export interface ProductRowProps {
  product: Product;
  input: LineInput;
  minStock?: MinStockLine;
  /**
   * What this line may take, when the caller knows better than the row does.
   *
   * It existed to add back this rep's own hold, so a row would not flag itself
   * the moment the booking they had just made landed from the ledger. There
   * are no holds now; the figure on the row is already what can be promised.
   */
  freeQty?: number | null;
  /** Rate is fixed once the Sales Manager has approved (2.2). */
  rateLocked?: boolean;
  onChange: (next: LineInput) => void;
}

export const ProductRow = memo(function ProductRow({
  product,
  input,
  minStock,
  freeQty,
  rateLocked = false,
  onChange,
}: ProductRowProps) {
  const computed = computeLine(product, input);
  const touched = hasQuantity(input);
  const issues = touched ? validateLine(product, input) : [];
  const issueFor = (field: string) => issues.find((i) => i.field === field)?.message;

  // An item whose master is incomplete would price at `rate x 0` and look
  // entirely normal on the proforma, so the row refuses it outright — before
  // anything is keyed, since waiting for a quantity would mean the rep only
  // finds out after doing the work.
  const broken = isMisconfigured(product);

  // What SAP can cover. The row says so before the rep gets as far as
  // submitting — it does not refuse the line, because an order for more than
  // the shelf holds is a normal order with a part to be made.
  const available = minStock ? (freeQty ?? shelfAvailable(minStock).rolls) : null;
  const oversold = available != null && computed.quantity > available;

  const set = (patch: Partial<LineInput>) => onChange({ ...input, ...patch });

  return (
    <div
      className={`prow ${touched ? 'is-active' : ''} ${oversold ? 'is-blocked' : ''} ${
        broken ? 'is-broken' : ''
      }`}
    >
      {/* ---------------------------------------------------- identity --- */}
      <div>
        <div className="prow__name">{product.name}</div>
        <div className="prow__spec">
          <span className="mono dim">{product.code}</span>
          {product.category === 'PCTR' && (
            <>
              <span>
                Avg <b>{round(rollWeight(product))} kg</b>/roll
              </span>
              <span>
                <b>{product.beltsPerRoll}</b> belts/roll
              </span>
              <span className="dim">
                1 belt = {round(beltWeight(product))} kg
              </span>
            </>
          )}
          {product.category === 'CTR' && (
            <span>
              Exact <b>{round(rollWeight(product))} kg</b>/roll
            </span>
          )}
          {product.category === 'BG' && (
            <span>
              1 box = {BG_KG_PER_BOX} kg ({BG_KG_PER_ROLL} kg × 4 rolls)
            </span>
          )}
          {product.category === 'VS' && (
            <span>
              <b>{product.tinSize}L</b> tin
            </span>
          )}
        </div>
        <div style={{ marginTop: 6 }}>
          <StockChip
            item={minStock}
            available={available ?? undefined}
            uom={product.category === 'PCTR' || product.category === 'CTR' ? 'rolls' : 'kg'}
          />
        </div>
        {broken && <div className="prow__broken">{broken}</div>}
      </div>

      {/* ------------------------------------------------------ inputs --- */}
      <div className="prow__inputs">
        {product.category === 'PCTR' && (
          <>
            <div className="prow__input">
              <Field label="Rolls" error={issueFor('rolls')}>
                <Input
                  numeric
                  compact
                  type="number"
                  min={0}
                  step={1}
                  placeholder="0"
                  value={input.rolls ?? ''}
                  invalid={Boolean(issueFor('rolls'))}
                  onChange={(e) => set({ rolls: toNum(e.target.value) })}
                />
              </Field>
            </div>
            <div className="prow__input">
              <Field label="Loose belts" error={issueFor('looseBelts')}>
                <Input
                  numeric
                  compact
                  type="number"
                  min={0}
                  step={1}
                  placeholder="0"
                  value={input.looseBelts ?? ''}
                  invalid={Boolean(issueFor('looseBelts'))}
                  onChange={(e) => set({ looseBelts: toNum(e.target.value) })}
                />
              </Field>
            </div>
          </>
        )}

        {product.category === 'CTR' && (
          // No loose-belt field: CTR is always sold as fixed-weight rolls (1.3).
          <div className="prow__input">
            <Field label="Rolls" error={issueFor('rolls')}>
              <Input
                numeric
                compact
                type="number"
                min={0}
                step={1}
                placeholder="0"
                value={input.rolls ?? ''}
                invalid={Boolean(issueFor('rolls'))}
                onChange={(e) => set({ rolls: toNum(e.target.value) })}
              />
            </Field>
          </div>
        )}

        {product.category === 'BG' && (
          <div className="prow__input--wide">
            <Field label="Quantity" error={issueFor('kg')}>
              <UnitInput
                suffix="kg"
                compact
                type="number"
                min={0}
                step={BG_KG_PER_ROLL}
                placeholder="0"
                value={input.kg ?? ''}
                invalid={Boolean(issueFor('kg'))}
                onChange={(e) => set({ kg: toNum(e.target.value) })}
                // Snap to a sellable 5 kg step as soon as focus leaves (1.4).
                onBlur={(e) => {
                  const raw = toNum(e.target.value);
                  if (raw && raw % BG_KG_PER_ROLL !== 0) set({ kg: snapBgKg(raw) });
                }}
              />
            </Field>
          </div>
        )}

        {product.category === 'VS' && (
          <div className="prow__input">
            <Field label={`${product.tinSize}L tins`} error={issueFor('tins')}>
              <Input
                numeric
                compact
                type="number"
                min={0}
                step={1}
                placeholder="0"
                value={input.tins ?? ''}
                invalid={Boolean(issueFor('tins'))}
                onChange={(e) => set({ tins: toNum(e.target.value), tinSize: product.tinSize })}
              />
            </Field>
          </div>
        )}

        <div className="prow__input--wide">
          <Field
            label={`Rate ${rateUnitFor(product.category)}`}
            error={issueFor('rate')}
            hint={rateLocked ? 'Locked' : undefined}
          >
            <UnitInput
              suffix="₹"
              compact
              type="number"
              min={0}
              step="0.01"
              placeholder={product.defaultRate ? String(product.defaultRate) : '0.00'}
              value={input.rate ?? ''}
              disabled={rateLocked}
              invalid={Boolean(issueFor('rate'))}
              onChange={(e) => set({ rate: toNum(e.target.value) })}
            />
          </Field>
        </div>
      </div>

      {/* ----------------------------------------------------- derived --- */}
      <div className="prow__derived">
        {touched ? (
          <>
            <div className="prow__qty">
              {computed.quantity.toLocaleString('en-IN', { maximumFractionDigits: 3 })}{' '}
              <span className="small muted">{computed.uom}</span>
            </div>
            <div className="prow__breakdown">{computed.breakdown}</div>
            {oversold && (
              <div className="small" style={{ color: 'var(--danger)', fontWeight: 600, marginTop: 3 }}>
                Only {round(available!)} {computed.uom} free
              </div>
            )}
          </>
        ) : (
          <span className="dim small">—</span>
        )}
      </div>

      <div className="prow__amount">
        {touched && computed.amount > 0 ? money(computed.amount, 2) : <span className="dim">—</span>}
      </div>
    </div>
  );
});

export function hasQuantity(input: LineInput): boolean {
  return Boolean(input.rolls || input.looseBelts || input.kg || input.tins);
}

function toNum(v: string): number | undefined {
  if (v === '') return undefined;
  const n = Number(v);
  return Number.isFinite(n) ? n : undefined;
}

function round(n: number): number {
  return Math.round(n * 100) / 100;
}
