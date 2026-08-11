/**
 * Phase 1 — order taking (spec 1.1 – 1.7).
 *
 * The rep picks a customer, keys quantities against the product list, and
 * raises the order. Three things are happening under the surface:
 *
 *  - Minimum-stock lines are *booked as you type*. The hold hits the shared
 *    ledger immediately, so another rep's screen shows the reduced availability
 *    within one poll and the same rolls cannot be sold twice (1.2).
 *  - Aged stock is offered alongside the requested item, so old inventory gets
 *    cleared before it goes stale (1.6).
 *  - A proforma is optional: the order can be raised for approval with or
 *    without one (1.3).
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { canStartOrder, NO_ROUTE_MESSAGE } from '@/domain/sales';
import type { MinStockItem, OrderItem, Product, ProductCategory } from '@/domain/types';
import { CATEGORY_LABEL } from '@/domain/types';
import {
  computeLine,
  uomFor,
  validateLine,
  type LineInput,
} from '@/domain/productRules';
import { todayIso } from '@/domain/orderRules';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import {
  selectCustomers,
  selectMinStockByCode,
  selectMinStockItems,
  selectProducts,
  selectReservations,
  selectUser,
} from '@/store/selectors';
import { createOrder } from '@/store/slices/ordersSlice';
import { releaseHolds, reserveStock } from '@/store/slices/minStockSlice';
import { pushToast } from '@/store/slices/notificationsSlice';
import { Alert, Button, Card, Field, Input, Segmented, Empty, Modal } from '@/components/ui';
import { money } from '@/components/common/format';
import { AgingPanel } from '@/features/stock/AgingPanel';
import { ProductRow, hasQuantity } from './ProductRow';
import { ProformaDocument } from './ProformaDocument';
import './orders.css';

type CategoryTab = ProductCategory | 'ALL';

const TABS: Array<{ id: CategoryTab; label: string }> = [
  { id: 'ALL', label: 'All' },
  { id: 'PCTR', label: 'PCTR' },
  { id: 'CTR', label: 'CTR' },
  { id: 'BG', label: 'Bonding Gum' },
  { id: 'VS', label: 'Vulcanizing Sol.' },
];

export function TakeOrderPage() {
  const { customerId } = useParams<{ customerId: string }>();
  const dispatch = useAppDispatch();
  const navigate = useNavigate();

  const user = useAppSelector(selectUser);
  const products = useAppSelector(selectProducts);
  const customers = useAppSelector(selectCustomers);
  const minStockByCode = useAppSelector(selectMinStockByCode);
  const minStockItems = useAppSelector(selectMinStockItems);
  const reservations = useAppSelector(selectReservations);
  const conflict = useAppSelector((s) => s.minStock.lastConflict);
  const saving = useAppSelector((s) => s.orders.saving);

  const customer = customers.find((c) => c.id === customerId);

  const [lines, setLines] = useState<Record<string, LineInput>>({});
  const [tab, setTab] = useState<CategoryTab>('ALL');
  const [search, setSearch] = useState('');
  const [deliveryDate, setDeliveryDate] = useState('');
  const [notes, setNotes] = useState('');
  const [showProforma, setShowProforma] = useState(false);
  const [submitAttempted, setSubmitAttempted] = useState(false);

  const productByCode = useMemo(
    () => new Map(products.map((p) => [p.code, p])),
    [products],
  );

  /**
   * What this rep may still take, per item: on-hand less *other* reps' holds.
   * Their own hold is excluded, otherwise the quantity they just keyed would
   * come back from the ledger and flag their own row as oversold (1.2).
   */
  const stockForMe = useMemo(() => {
    const byOthers = new Map<string, number>();
    reservations.forEach((r) => {
      if (user && r.repId === user.id) return;
      byOthers.set(r.itemCode, (byOthers.get(r.itemCode) ?? 0) + r.qty);
    });
    const free = new Map<string, number>();
    minStockItems.forEach((item) => {
      free.set(item.itemCode, Math.max(0, item.onHand - (byOthers.get(item.itemCode) ?? 0)));
    });
    return { free, byOthers };
  }, [reservations, minStockItems, user]);

  // ---------------------------------------------------------- reserving ---
  //
  // Booking on every keystroke would hammer the ledger, so each item's hold is
  // debounced. The hold is placed against a null order id until the order is
  // actually saved, at which point it is bound to it.
  const timers = useRef<Record<string, number>>({});

  const bookStock = useCallback(
    (code: string, quantity: number) => {
      if (!user || !minStockByCode.has(code)) return;
      window.clearTimeout(timers.current[code]);
      timers.current[code] = window.setTimeout(() => {
        void dispatch(reserveStock({ itemCode: code, qty: quantity, user, orderId: null }));
      }, 400);
    },
    [dispatch, user, minStockByCode],
  );

  // Walking away from a half-typed order must not strand stock for other reps.
  useEffect(() => {
    const held = timers.current;
    return () => {
      Object.values(held).forEach((t) => window.clearTimeout(t));
      if (user) void dispatch(releaseHolds({ user, orderId: null }));
    };
  }, [dispatch, user]);

  const updateLine = useCallback(
    (product: Product, next: LineInput) => {
      setLines((prev) => ({ ...prev, [product.code]: next }));
      const { quantity } = computeLine(product, next);
      bookStock(product.code, quantity);
    },
    [bookStock],
  );

  // -------------------------------------------------------------- derived ---

  const selected = useMemo(
    () =>
      Object.entries(lines)
        .filter(([, input]) => hasQuantity(input))
        .map(([code, input]) => {
          const product = productByCode.get(code)!;
          return { product, input, computed: computeLine(product, input) };
        })
        .filter((l) => l.product),
    [lines, productByCode],
  );

  const total = selected.reduce((s, l) => s + l.computed.amount, 0);

  const problems = useMemo(() => {
    const list: string[] = [];
    selected.forEach(({ product, input, computed }) => {
      validateLine(product, input).forEach((issue) =>
        list.push(`${product.name}: ${issue.message}`),
      );
      const available = stockForMe.free.get(product.code);
      if (available != null && computed.quantity > available) {
        list.push(
          `${product.name}: only ${round(available)} ${computed.uom} of minimum stock is free — the rest is booked by other reps.`,
        );
      }
    });
    if (!deliveryDate) list.push('Pick a requested delivery date.');
    if (!selected.length) list.push('Add at least one product.');
    return list;
  }, [selected, stockForMe, deliveryDate]);

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase();
    return products.filter((p) => {
      if (tab !== 'ALL' && p.category !== tab) return false;
      if (!q) return true;
      return `${p.name} ${p.code} ${p.size ?? ''}`.toLowerCase().includes(q);
    });
  }, [products, tab, search]);

  const grouped = useMemo(() => {
    const map = new Map<ProductCategory, Product[]>();
    filtered.forEach((p) => {
      const list = map.get(p.category) ?? [];
      list.push(p);
      map.set(p.category, list);
    });
    return [...map.entries()];
  }, [filtered]);

  // --------------------------------------------------------------- submit ---

  const buildItems = (): Array<Omit<OrderItem, 'id' | 'rateLocked'>> =>
    selected.map(({ product, input, computed }) => ({
      itemCode: product.code,
      itemName: product.name,
      category: product.category,
      rolls: input.rolls,
      looseBelts: input.looseBelts,
      kg: input.kg,
      tins: input.tins,
      tinSize: input.tinSize ?? product.tinSize,
      quantity: computed.quantity,
      uom: uomFor(product.category),
      quotedRate: input.rate ?? 0,
    }));

  const submit = async (generateProforma: boolean) => {
    setSubmitAttempted(true);
    if (problems.length || !user || !customer) return;

    const result = await dispatch(
      createOrder({
        customerId: customer.id,
        customerName: customer.name,
        destination: customer.destination,
        deliveryDate,
        items: buildItems(),
        generateProforma,
        notes: notes.trim() || undefined,
        user,
      }),
    );

    if (createOrder.fulfilled.match(result)) {
      dispatch(
        pushToast(
          `${result.payload.orderNo} raised for approval${generateProforma ? ' with proforma' : ''}.`,
          'success',
        ),
      );
      navigate(`/orders/${result.payload.id}`);
    }
  };

  /** Swap a requested line onto an aged batch after checking with the customer (1.6). */
  const substitute = (item: MinStockItem) => {
    const product = productByCode.get(item.itemCode);
    if (!product) return;
    setTab(product.category);
    setSearch(product.name);
    dispatch(
      pushToast(
        `Showing ${item.itemName} — confirm the substitution with the customer before booking.`,
        'info',
      ),
    );
  };

  if (!user) return null;
  if (!customer) {
    return (
      <Empty
        icon="👤"
        title="Customer not found"
        action={<Button onClick={() => navigate('/customers')}>Back to customers</Button>}
      >
        Pick a customer to take an order against.
      </Empty>
    );
  }

  /*
   * §7.7 — a party with no sales route cannot be ordered for at all.
   *
   * Refused before the screen opens rather than at submit: letting someone key
   * a full order and then rejecting it wastes the work and teaches nothing
   * about what to fix. The route decides which delivery run the goods go out
   * on, and nothing downstream asks for it again.
   */
  if (!canStartOrder({ route: customer.route })) {
    return (
      <Empty
        icon="🛣"
        title={`${customer.name} has no sales route`}
        action={<Button onClick={() => navigate('/customers')}>Assign a route</Button>}
      >
        {NO_ROUTE_MESSAGE}
      </Empty>
    );
  }

  const showProblems = submitAttempted && problems.length > 0;

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Take order — {customer.name}</div>
          <div className="page-head__sub">
            {customer.destination} · GST {customer.gstin || '—'}
          </div>
        </div>
        <Button variant="ghost" onClick={() => navigate('/customers')}>
          ← Customers
        </Button>
      </div>

      {conflict && (
        <div style={{ marginBottom: 12 }}>
          <Alert tone="warn" title="Stock booked by another rep">
            {conflict}
          </Alert>
        </div>
      )}

      <div className="take-order">
        <div>
          <div className="order-toolbar">
            <Input
              placeholder="Search products by name, code or size…"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              style={{ maxWidth: 300 }}
            />
            <Segmented
              ariaLabel="Product category"
              value={tab}
              onChange={setTab}
              options={TABS.map((t) => ({ value: t.id, label: t.label }))}
            />
            <div className="grow" />
            <div style={{ minWidth: 190 }}>
              <Field
                label="Requested delivery date"
                error={showProblems && !deliveryDate ? 'Required' : undefined}
                hint={deliveryDate ? 'Edits close 1:00 PM that day' : undefined}
              >
                <Input
                  type="date"
                  compact
                  min={todayIso()}
                  value={deliveryDate}
                  invalid={showProblems && !deliveryDate}
                  onChange={(e) => setDeliveryDate(e.target.value)}
                />
              </Field>
            </div>
          </div>

          <Card flush>
            {grouped.length === 0 && (
              <Empty icon="🔍" title="No matching products">
                Try a different search or category.
              </Empty>
            )}

            {grouped.map(([category, items]) => (
              <div key={category}>
                <div
                  className="row gap-2"
                  style={{
                    padding: '9px 14px',
                    background: 'var(--surface-2)',
                    borderBottom: '1px solid var(--border)',
                    position: 'sticky',
                    top: 0,
                    zIndex: 2,
                  }}
                >
                  <strong className="small">{CATEGORY_LABEL[category]}</strong>
                  <span className="tiny dim">({items.length})</span>
                </div>

                {items.map((product) => (
                  <ProductRow
                    key={product.code}
                    product={product}
                    input={lines[product.code] ?? {}}
                    minStock={minStockByCode.get(product.code)}
                    freeQty={stockForMe.free.get(product.code) ?? null}
                    reservedByOthers={stockForMe.byOthers.get(product.code) ?? 0}
                    onChange={(next) => updateLine(product, next)}
                  />
                ))}
              </div>
            ))}
          </Card>
        </div>

        {/* ------------------------------------------------------ cart --- */}
        <div className="cart stack gap-3">
          <Card title={`Order summary (${selected.length})`}>
            {selected.length === 0 ? (
              <p className="small dim">Key a quantity against any product to start.</p>
            ) : (
              <>
                {selected.map(({ product, computed }) => (
                  <div key={product.code} className="cart__line">
                    <div className="grow">
                      <div className="cart__name">{product.name}</div>
                      <div className="cart__detail">{computed.breakdown}</div>
                      <div className="cart__detail">
                        {computed.quantity.toLocaleString('en-IN', { maximumFractionDigits: 3 })}{' '}
                        {computed.uom}
                        {minStockByCode.has(product.code) && ' · booked from min stock'}
                      </div>
                    </div>
                    <div className="cart__amount">{money(computed.amount, 2)}</div>
                  </div>
                ))}

                <div className="cart__total">
                  <span className="small muted">Order value</span>
                  <span className="cart__total-value">{money(total, 2)}</span>
                </div>
              </>
            )}

            <div style={{ marginTop: 12 }}>
              <Field label="Notes (optional)">
                <Input
                  placeholder="Anything the manager should know"
                  value={notes}
                  onChange={(e) => setNotes(e.target.value)}
                />
              </Field>
            </div>

            {showProblems && (
              <div style={{ marginTop: 12 }}>
                <Alert tone="danger" title="Fix before raising">
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

            <div className="stack gap-2" style={{ marginTop: 14 }}>
              <Button
                variant="primary"
                block
                loading={saving}
                onClick={() => void submit(true)}
              >
                Generate proforma &amp; raise
              </Button>
              {/* Proforma is optional — 1.3. */}
              <Button block loading={saving} onClick={() => void submit(false)}>
                Raise without proforma
              </Button>
              <Button
                block
                variant="ghost"
                disabled={!selected.length || !deliveryDate}
                onClick={() => setShowProforma(true)}
              >
                Preview proforma
              </Button>
            </div>
          </Card>

          <Card title="Aged stock">
            <AgingPanel items={minStockItems} onSubstitute={substitute} />
          </Card>
        </div>
      </div>

      {showProforma && (
        <Modal
          title="Proforma preview"
          width="wide"
          onClose={() => setShowProforma(false)}
          footer={
            <>
              <Button onClick={() => setShowProforma(false)}>Close</Button>
              <Button variant="primary" onClick={() => window.print()}>
                Print
              </Button>
            </>
          }
        >
          <ProformaDocument
            customer={customer}
            deliveryDate={deliveryDate}
            proformaNo="PF-DRAFT"
            lines={selected.map(({ product, input, computed }) => ({
              itemName: product.name,
              hsn: product.hsnCode,
              detail: computed.breakdown,
              quantity: computed.quantity,
              uom: computed.uom,
              rate: input.rate ?? 0,
              amount: computed.amount,
              category: product.category,
              tins: input.tins,
            }))}
          />
        </Modal>
      )}
    </div>
  );
}

function round(n: number): number {
  return Math.round(n * 100) / 100;
}
