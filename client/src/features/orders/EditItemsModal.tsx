/**
 * Post-approval item editing (3.3).
 *
 * Reps and Sales Managers keep the right to change products and quantities even
 * once production has started — the only thing bolted down is a finalised rate
 * (2.2), which renders read-only here rather than being hidden, so everyone can
 * still see what was agreed.
 *
 * Saving from this modal is what raises the must-acknowledge alert to the floor.
 */

import { useMemo, useState } from 'react';
import type { Order, OrderItem, User } from '@/domain/types';
import { CATEGORY_LABEL } from '@/domain/types';
import { computeLine, uomFor, validateLine, type LineInput } from '@/domain/productRules';
import { isPostApprovalEdit, isRateLocked } from '@/domain/orderRules';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import { selectMinStockByCode, selectProducts, selectReservations } from '@/store/selectors';
import { updateOrderItems } from '@/store/slices/ordersSlice';
import { pushToast } from '@/store/slices/notificationsSlice';
import { Alert, Button, Field, Input, Modal, Select } from '@/components/ui';
import { money } from '@/components/common/format';
import { ProductRow } from './ProductRow';

interface Draft {
  item: OrderItem;
  input: LineInput;
}

export function EditItemsModal({
  order,
  user,
  onClose,
}: {
  order: Order;
  user: User;
  onClose: () => void;
}) {
  const dispatch = useAppDispatch();
  const products = useAppSelector(selectProducts);
  const minStockByCode = useAppSelector(selectMinStockByCode);
  const reservations = useAppSelector(selectReservations);
  const saving = useAppSelector((s) => s.orders.saving);
  const error = useAppSelector((s) => s.orders.error);

  const productByCode = useMemo(() => new Map(products.map((p) => [p.code, p])), [products]);

  /**
   * Stock free to *this* order: on hand, less holds belonging to other orders.
   * Without this the rows fall back to StockChip's "not tracked" branch and
   * every line wrongly reads "No minimum stock" while quantities are edited.
   */
  const stockForOrder = useMemo(() => {
    const byOthers = new Map<string, number>();
    reservations.forEach((r) => {
      if (r.orderId === order.id) return;
      byOthers.set(r.itemCode, (byOthers.get(r.itemCode) ?? 0) + r.qty);
    });
    const free = new Map<string, number>();
    minStockByCode.forEach((item, code) => {
      free.set(code, Math.max(0, item.onHand - (byOthers.get(code) ?? 0)));
    });
    return { free, byOthers };
  }, [reservations, minStockByCode, order.id]);

  const [drafts, setDrafts] = useState<Draft[]>(() =>
    order.items.map((item) => ({ item, input: toInput(item) })),
  );
  const [addCode, setAddCode] = useState('');
  const [note, setNote] = useState('');

  const postApproval = isPostApprovalEdit(order);

  const problems = useMemo(() => {
    const list: string[] = [];
    if (!drafts.length) list.push('An order must keep at least one item.');
    drafts.forEach(({ item, input }) => {
      const product = productByCode.get(item.itemCode);
      if (!product) return;
      validateLine(product, input).forEach((i) => list.push(`${item.itemName}: ${i.message}`));
    });
    return list;
  }, [drafts, productByCode]);

  const total = drafts.reduce((sum, { item, input }) => {
    const product = productByCode.get(item.itemCode);
    if (!product) return sum;
    return sum + computeLine(product, input).amount;
  }, 0);

  const addItem = () => {
    const product = productByCode.get(addCode);
    if (!product) return;
    const item: OrderItem = {
      id: `NEW-${product.code}-${Date.now()}`,
      itemCode: product.code,
      itemName: product.name,
      category: product.category,
      quantity: 0,
      uom: uomFor(product.category),
      quotedRate: product.defaultRate ?? 0,
      rateLocked: false,
      tinSize: product.tinSize,
    };
    setDrafts((d) => [...d, { item, input: { rate: product.defaultRate, tinSize: product.tinSize } }]);
    setAddCode('');
  };

  const save = async () => {
    if (problems.length) return;

    const items: OrderItem[] = drafts.map(({ item, input }) => {
      const product = productByCode.get(item.itemCode)!;
      const computed = computeLine(product, input);
      return {
        ...item,
        rolls: input.rolls,
        looseBelts: input.looseBelts,
        kg: input.kg,
        tins: input.tins,
        tinSize: input.tinSize ?? item.tinSize,
        quantity: computed.quantity,
        uom: computed.uom,
        // A locked rate is preserved by the service too — this is belt and braces.
        quotedRate: isRateLocked(item, order) ? item.quotedRate : input.rate ?? 0,
      };
    });

    const result = await dispatch(
      updateOrderItems({ orderId: order.id, items, user, note: note.trim() || undefined }),
    );

    if (updateOrderItems.fulfilled.match(result)) {
      dispatch(
        pushToast(
          postApproval
            ? 'Saved. The Production Manager has been alerted and must acknowledge the change.'
            : 'Order items updated.',
          postApproval ? 'warning' : 'success',
        ),
      );
      onClose();
    }
  };

  const available = products.filter((p) => !drafts.some((d) => d.item.itemCode === p.code));

  return (
    <Modal
      title={`Edit items — ${order.orderNo}`}
      width="xwide"
      onClose={onClose}
      footer={
        <>
          <span className="grow row gap-2">
            <span className="muted small">New order value</span>
            <strong className="num">{money(total, 2)}</strong>
          </span>
          <Button onClick={onClose}>Cancel</Button>
          <Button
            variant="primary"
            loading={saving}
            disabled={problems.length > 0}
            onClick={() => void save()}
          >
            Save changes
          </Button>
        </>
      }
    >
      {postApproval && (
        <div style={{ marginBottom: 14 }}>
          <Alert tone="warn" title="This order is already approved">
            Production is working to it. Saving will send an alert the Production Manager has to
            acknowledge before the change is treated as seen on the floor. Finalised rates cannot be
            changed.
          </Alert>
        </div>
      )}

      {error && (
        <div style={{ marginBottom: 14 }}>
          <Alert tone="danger">{error}</Alert>
        </div>
      )}

      <div style={{ border: '1px solid var(--border)', borderRadius: 'var(--r)' }}>
        {drafts.map(({ item, input }, index) => {
          const product = productByCode.get(item.itemCode);
          if (!product) {
            return (
              <div key={item.id} className="prow">
                <div className="small">
                  {item.itemName}
                  <div className="tiny dim">
                    This item is no longer in the catalogue — remove it or re-import products.
                  </div>
                </div>
                <div />
                <div />
                <Button size="sm" variant="danger" onClick={() => remove(index)}>
                  Remove
                </Button>
              </div>
            );
          }
          return (
            <div key={item.id} style={{ display: 'flex', alignItems: 'stretch' }}>
              <div className="grow" style={{ minWidth: 0 }}>
                <ProductRow
                  product={product}
                  input={input}
                  minStock={minStockByCode.get(item.itemCode)}
                  freeQty={stockForOrder.free.get(item.itemCode) ?? null}
                  reservedByOthers={stockForOrder.byOthers.get(item.itemCode) ?? 0}
                  rateLocked={isRateLocked(item, order)}
                  onChange={(next) =>
                    setDrafts((d) =>
                      d.map((row, i) => (i === index ? { ...row, input: next } : row)),
                    )
                  }
                />
              </div>
              <div
                style={{
                  display: 'grid',
                  placeItems: 'center',
                  padding: '0 12px',
                  borderBottom: '1px solid var(--border)',
                }}
              >
                <Button
                  size="sm"
                  variant="ghost"
                  iconOnly
                  aria-label={`Remove ${item.itemName}`}
                  onClick={() => remove(index)}
                >
                  🗑
                </Button>
              </div>
            </div>
          );
        })}
      </div>

      <div className="row gap-2" style={{ marginTop: 14 }}>
        <div style={{ minWidth: 280 }}>
          <Field label="Add an item">
            <Select value={addCode} onChange={(e) => setAddCode(e.target.value)}>
              <option value="">Select a product…</option>
              {(['PCTR', 'CTR', 'BG', 'VS'] as const).map((cat) => (
                <optgroup key={cat} label={CATEGORY_LABEL[cat]}>
                  {available
                    .filter((p) => p.category === cat)
                    .map((p) => (
                      <option key={p.code} value={p.code}>
                        {p.name}
                      </option>
                    ))}
                </optgroup>
              ))}
            </Select>
          </Field>
        </div>
        <Button style={{ marginTop: 18 }} disabled={!addCode} onClick={addItem}>
          Add
        </Button>
        <div className="grow" />
        <div style={{ minWidth: 260, marginTop: 0 }}>
          <Field label="Reason for the change (goes to production)">
            <Input
              placeholder="e.g. customer increased quantity"
              value={note}
              onChange={(e) => setNote(e.target.value)}
            />
          </Field>
        </div>
      </div>

      {problems.length > 0 && (
        <div style={{ marginTop: 14 }}>
          <Alert tone="danger" title="Fix before saving">
            <ul style={{ margin: '4px 0 0', paddingLeft: 16 }}>
              {problems.map((p) => (
                <li key={p} className="small">
                  {p}
                </li>
              ))}
            </ul>
          </Alert>
        </div>
      )}
    </Modal>
  );

  function remove(index: number) {
    setDrafts((d) => d.filter((_, i) => i !== index));
  }
}

function toInput(item: OrderItem): LineInput {
  return {
    rolls: item.rolls,
    looseBelts: item.looseBelts,
    kg: item.kg,
    tins: item.tins,
    tinSize: item.tinSize,
    rate: item.finalRate ?? item.quotedRate,
  };
}
