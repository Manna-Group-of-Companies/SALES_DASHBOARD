/**
 * Team Analysis — how each rep under this manager is selling, over time.
 *
 * Asked for 11 Oct 2026: per rep, by week or month, customer-wise, in rupees
 * and in tonnes, with the trend of sales and of outstanding, "as customizable
 * and as informative as possible". Built first as a SAMPLE on invented
 * figures so the layout can be agreed before the real source is wired — see
 * `sampleData.ts` for why there is no real history to draw yet.
 *
 * Like every dashboard here it summarises and never decides: no control on
 * this page writes anything.
 *
 * Gated like the customer list (`TeamRoute screen="customers"`): a manager who
 * may see their team's customers may see what those customers bought.
 */

import { useEffect, useMemo, useState } from 'react';
import { Api } from '@/api/client';
import type { SalesPerson } from '@/domain/types';
import { scopeFor, NO_TEAM_MESSAGE } from '@/domain/sales';
import { isPooledUnit } from '@/domain/visibility';
import { todayIso, formatDate } from '@/domain/orderRules';
import {
  alignedSeries,
  bucketsBetween,
  byCustomer,
  byGroup,
  byRep,
  change,
  comparisonRange,
  dso,
  inRange,
  measureOf,
  outstandingSeries,
  presetRange,
  series,
  totals,
  trendSlope,
  type Compare,
  type CustomerFlag,
  type CustomerRow,
  type Grain,
  type Measure,
  type OutstandingPoint,
  type Preset,
  type Range,
  type SaleLine,
} from '@/domain/repAnalysis';
import { useAppSelector } from '@/store/hooks';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Button, Card, Empty, Input, Segmented, Select } from '@/components/ui';
import { money, moneyShort } from '@/components/common/format';
import { buildSample, type SampleData } from './sampleData';
import { HBars, MultiLineChart, Sparkline, StackedBars, TrendChart } from './charts';
import '@/components/layout/layout.css';
import './analysis.css';

// ------------------------------------------------------------ settings ---

interface Settings {
  rep: string;
  preset: Preset;
  from: string;
  to: string;
  grain: Grain;
  measure: Measure;
  compare: Compare;
  group: string;
  showTrend: boolean;
  dormantDays: number;
}

const STORE_KEY = 'manna.analysis.settings.v1';

function loadSettings(today: string): Settings {
  const fallback: Settings = {
    rep: '',
    preset: '6m',
    ...presetRange('6m', today),
    grain: 'month',
    measure: 'amount',
    compare: 'previous',
    group: '',
    showTrend: true,
    dormantDays: 45,
  };
  try {
    const raw = localStorage.getItem(STORE_KEY);
    return raw ? { ...fallback, ...(JSON.parse(raw) as Partial<Settings>) } : fallback;
  } catch {
    return fallback;
  }
}

const PRESETS: Array<{ value: Preset; label: string }> = [
  { value: '4w', label: '4 weeks' },
  { value: '12w', label: '12 weeks' },
  { value: '26w', label: '26 weeks' },
  { value: '3m', label: '3 months' },
  { value: '6m', label: '6 months' },
  { value: '12m', label: '12 months' },
  { value: 'fy', label: 'This FY' },
  { value: 'ytd', label: 'This year' },
  { value: 'custom', label: 'Custom…' },
];

/** What a preset reads best in; the manager can still override it. */
function suggestedGrain(p: Preset): Grain {
  return p === '4w' || p === '12w' || p === '26w' ? 'week' : 'month';
}

/** Categorical slots in fixed order. A rep keeps their colour whatever is filtered. */
const SERIES = ['var(--viz-1)', 'var(--viz-2)', 'var(--viz-3)', 'var(--viz-4)', 'var(--viz-5)', 'var(--viz-6)', 'var(--viz-7)', 'var(--viz-8)'];
const AGE_KEYS = ['0–30 days', '31–60', '61–90', '90+ days'];
const AGE_COLORS = ['var(--viz-age-1)', 'var(--viz-age-2)', 'var(--viz-age-3)', 'var(--viz-age-4)'];

const FLAG_LABEL: Record<CustomerFlag, string> = {
  new: 'New',
  lost: 'Stopped buying',
  dormant: 'Gone quiet',
  falling: 'Falling',
  rising: 'Rising',
};
const FLAG_TONE: Record<CustomerFlag, 'ok' | 'warn' | 'danger' | 'info'> = {
  new: 'info',
  lost: 'danger',
  dormant: 'warn',
  falling: 'warn',
  rising: 'ok',
};

// ------------------------------------------------------------- formats ---

function tonnes(kg: number): string {
  const t = kg / 1000;
  return `${t.toLocaleString('en-IN', { maximumFractionDigits: t < 10 ? 2 : 1 })} t`;
}

function fmt(v: number, m: Measure): string {
  return m === 'amount' ? moneyShort(v) : tonnes(v);
}

function pct(ch: number | null, digits = 1): string {
  if (ch === null) return '—';
  return `${ch >= 0 ? '+' : ''}${(ch * 100).toFixed(digits)}%`;
}

/** ▲/▼ with the number — direction is never carried by colour alone. */
function Delta({ value, invert }: { value: number | null; invert?: boolean }) {
  if (value === null) return <span className="delta delta--none">no comparison</span>;
  const good = invert ? value < 0 : value > 0;
  const flat = Math.abs(value) < 0.005;
  return (
    <span className={`delta ${flat ? '' : good ? 'delta--good' : 'delta--bad'}`}>
      {flat ? '◆' : value > 0 ? '▲' : '▼'} {pct(value)}
    </span>
  );
}

// ---------------------------------------------------------------- page ---

type SortKey = 'name' | 'value' | 'change' | 'perKg' | 'orders' | 'last' | 'outstanding' | 'overdue';
type FlagFilter = 'all' | CustomerFlag | 'overdue';

export function RepAnalysisPage() {
  const user = useAppSelector(selectUser);
  const today = todayIso();

  const [people, setPeople] = useState<SalesPerson[]>([]);
  const [team, setTeam] = useState<string[]>([]);
  const [data, setData] = useState<SampleData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  const [s, setS] = useState<Settings>(() => loadSettings(today));
  const set = (patch: Partial<Settings>) => setS((prev) => ({ ...prev, ...patch }));
  useEffect(() => {
    try {
      localStorage.setItem(STORE_KEY, JSON.stringify(s));
    } catch {
      /* private window — settings simply are not remembered */
    }
  }, [s]);

  const [query, setQuery] = useState('');
  const [flag, setFlag] = useState<FlagFilter>('all');
  const [sort, setSort] = useState<{ key: SortKey; desc: boolean }>({ key: 'value', desc: true });
  const [showAll, setShowAll] = useState(false);
  const [open, setOpen] = useState<string | null>(null);

  // --- load: the real team and its real customers; the history is sample ---
  useEffect(() => {
    let live = true;
    setLoading(true);
    setError(null);
    Api.attendance
      .listSalesPeople()
      .then(async (p) => {
        if (!live) return;
        setPeople(p);
        const scope = scopeFor(p, user?.salesPerson);
        // Fail closed, as every team screen does: no team, nothing shown.
        if (!scope) {
          setError(NO_TEAM_MESSAGE);
          return;
        }
        const unit = p.find((x) => x.id === user?.salesPerson)?.unit;
        const customers = await Api.sales
          .listCustomers(isPooledUnit(unit) ? [...scope, ''] : scope, unit ?? undefined)
          .catch(() => []);
        if (!live) return;
        setTeam(scope);
        setData(
          buildSample(
            scope,
            customers
              .filter((c) => c.assignedRep && scope.includes(c.assignedRep))
              .map((c) => ({ id: c.id, name: c.name, rep: c.assignedRep! })),
            today,
          ),
        );
      })
      .catch((e: unknown) => live && setError(e instanceof Error ? e.message : 'Could not read the team.'))
      .finally(() => live && setLoading(false));
    return () => {
      live = false;
    };
  }, [user, today]);

  const nameOf = (id: string) => people.find((p) => p.id === id)?.name ?? id;
  const colorOf = (id: string) => SERIES[team.indexOf(id) % SERIES.length];

  // ------------------------------------------------------------ derive ---
  const range: Range = s.preset === 'custom' ? { from: s.from, to: s.to } : presetRange(s.preset, today);
  const cmpRange = comparisonRange(range, s.compare);
  const compareLabel =
    s.compare === 'lastYear' ? 'Same period last year' : s.compare === 'previous' ? 'Previous period' : '';

  const view = useMemo(
    () => (data ? computeView(data, s, team, range, cmpRange) : null),
    // range/cmpRange are derived from `s` and `today`.
    [data, s, team, today],
  );

  if (!user) return null;

  return (
    <div className="analysis">
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Team Analysis</div>
          <div className="page-head__sub">
            {s.rep ? nameOf(s.rep) : `Whole team · ${team.length} people`} · {formatDate(range.from)} –{' '}
            {formatDate(range.to)}
          </div>
        </div>
        {view && (
          <Button variant="ghost" onClick={() => void exportXlsx(view, s, range, nameOf)}>
            Export to Excel
          </Button>
        )}
      </div>

      <Alert tone="warn" title="Sample figures — not real sales">
        This is a layout to agree on. The reps and customers are your real ones; every amount, tonnage and
        outstanding figure is invented. ERPNext doesn't have the sales history yet (it lives in SAP), so the real
        numbers come once this layout is settled.
      </Alert>

      {loading && <Empty icon="◔" title="Reading your team…" />}
      {error && <Alert tone="danger" title="Nothing to show">{error}</Alert>}

      {view && (
        <>
          <Filters
            s={s}
            set={set}
            team={team}
            nameOf={nameOf}
            groups={view.allGroups}
            today={today}
          />

          <Kpis view={view} s={s} cmpOn={!!cmpRange} reps={view.reps} />

          <Insights view={view} s={s} nameOf={nameOf} compareLabel={compareLabel} grain={s.grain} />

          <div className="analysis-grid">
            <Card
              className="span-2"
              title={`Sales trend · ${s.measure === 'amount' ? 'rupees' : 'tonnes'} per ${s.grain}`}
              actions={
                <label className="analysis-check">
                  <input type="checkbox" checked={s.showTrend} onChange={(e) => set({ showTrend: e.target.checked })} />
                  Trend line
                </label>
              }
            >
              <div className="viz-legend">
                <span className="viz-legend__item"><span className="viz-swatch" style={{ background: 'var(--viz-1)' }} />This period</span>
                {cmpRange && <span className="viz-legend__item"><span className="viz-swatch viz-swatch--line viz-swatch--dash" />{compareLabel}</span>}
                {s.showTrend && <span className="viz-legend__item"><span className="viz-swatch viz-swatch--line viz-swatch--dot" />Trend ({pct(view.slope)} per {s.grain})</span>}
              </div>
              <TrendChart
                points={view.curSeries.map((p, i) => ({
                  label: p.label,
                  value: measureOf(p, s.measure),
                  compare: cmpRange ? measureOf(view.prevSeries[i] ?? { amount: 0, kg: 0 }, s.measure) : undefined,
                  detail: `${p.orders} orders · ${s.measure === 'amount' ? tonnes(p.kg) : moneyShort(p.amount)}${
                    p.kg > 0 ? ` · ₹${Math.round(p.amount / p.kg)}/kg` : ''
                  }`,
                }))}
                format={(v) => fmt(v, s.measure)}
                compareLabel={compareLabel}
                showTrend={s.showTrend}
              />
            </Card>

            {!s.rep && team.length > 1 && (
              <Card className="span-2" title="Rep comparison" actions={<span className="muted small">Click a rep to open their view</span>}>
                <MultiLineChart
                  labels={view.buckets.map((b) => b.label)}
                  series={view.reps.map((r) => ({ id: r.rep, label: nameOf(r.rep), color: colorOf(r.rep), values: r.spark }))}
                  format={(v) => fmt(v, s.measure)}
                  onPick={(id) => set({ rep: id })}
                />
                <RepTable reps={view.reps} s={s} nameOf={nameOf} colorOf={colorOf} range={range} cmpOn={!!cmpRange} onPick={(id) => set({ rep: id })} />
              </Card>
            )}

            <Card title="Outstanding over time, by age" className="span-2">
              <StackedBars
                points={view.owedSeries.map((o) => ({ label: o.label, parts: [o.d0_30, o.d30_60, o.d60_90, o.d90] }))}
                keys={AGE_KEYS}
                colors={AGE_COLORS}
                format={moneyShort}
              />
              <div className="muted small analysis-note">
                Each bar is what was owed at the end of that {s.grain}. Showing this for real means keeping a copy of
                SAP's balances each night; today ERPNext keeps only the latest. Product filter doesn't apply here.
              </div>
            </Card>

            <Card title="Product mix">
              {view.groups.length === 0 ? (
                <Empty title="No sales in this range" />
              ) : (
                <HBars
                  rows={view.groups.map((g) => ({
                    id: g.group,
                    label: g.group.replace(/^FG - TRP - /, ''),
                    value: measureOf(g, s.measure),
                    note: `${fmt(measureOf(g, s.measure), s.measure)} · ${(g.share * 100).toFixed(0)}% · ₹${Math.round(g.perKg)}/kg`,
                    title: g.group,
                  }))}
                  active={s.group}
                  onPick={(id) => set({ group: s.group === id ? '' : id })}
                />
              )}
              <div className="muted small analysis-note">Click a product to filter the whole page by it.</div>
            </Card>

            <Card title="Customer movement">
              <Movement customers={view.customers} flag={flag} setFlag={setFlag} cmpOn={!!cmpRange} dormantDays={s.dormantDays} />
            </Card>

            <Card className="span-2" title="Customers" flush>
              <CustomerTable
                rows={view.customers}
                s={s}
                nameOf={nameOf}
                query={query}
                setQuery={setQuery}
                flag={flag}
                setFlag={setFlag}
                sort={sort}
                setSort={setSort}
                showAll={showAll}
                setShowAll={setShowAll}
                open={open}
                setOpen={setOpen}
                data={data!}
                range={range}
                cmpRange={cmpRange}
                compareLabel={compareLabel}
              />
            </Card>
          </div>
        </>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- view ---

function computeView(data: SampleData, s: Settings, team: string[], range: Range, cmpRange: Range | undefined) {
  const m = s.measure;
  const byGroupFilter = (l: SaleLine) => !s.group || l.group === s.group;
  const allLines = data.lines.filter(byGroupFilter);
  const scoped = s.rep ? allLines.filter((l) => l.rep === s.rep) : allLines;

  const cur = inRange(scoped, range);
  const prev = cmpRange ? inRange(scoped, cmpRange) : [];
  const teamCur = inRange(allLines, range);
  const teamPrev = cmpRange ? inRange(allLines, cmpRange) : undefined;

  const buckets = bucketsBetween(range, s.grain);
  const curSeries = series(cur, buckets, s.grain);
  const prevSeries = cmpRange ? alignedSeries(prev, cmpRange, s.grain, buckets.length) : [];

  // Outstanding is a level as of a date, so it is read up to the range's end.
  const owedAll = data.outstanding.filter((o) => !s.rep || o.rep === s.rep);
  const owedToEnd = owedAll.filter((o) => o.date <= range.to);
  const owedSeries = outstandingSeries(owedAll, buckets);
  const owedNow = outstandingSeries(owedAll, [{ key: 'now', label: '', start: range.to, end: range.to }])[0];
  const owedBefore = cmpRange
    ? outstandingSeries(owedAll, [{ key: 'then', label: '', start: cmpRange.to, end: cmpRange.to }])[0]
    : undefined;

  const t = totals(cur);
  const p = totals(prev);
  const reps = byRep(
    team,
    teamCur,
    teamPrev,
    data.outstanding.filter((o) => o.date <= range.to),
    buckets,
    s.grain,
    m,
  );
  const customers = byCustomer(cur, prev, owedToEnd, buckets, s.grain, m, range.to, s.dormantDays);
  const groups = byGroup(cur, m);
  const allGroups = [...new Set(data.lines.map((l) => l.group))].sort();
  const slope = trendSlope(curSeries.map((x) => measureOf(x, m)));

  return { cur, prev, t, p, buckets, curSeries, prevSeries, owedSeries, owedNow, owedBefore, reps, customers, groups, allGroups, slope };
}

type View = ReturnType<typeof computeView>;

// ------------------------------------------------------------- filters ---

function Filters({
  s,
  set,
  team,
  nameOf,
  groups,
  today,
}: {
  s: Settings;
  set: (p: Partial<Settings>) => void;
  team: string[];
  nameOf: (id: string) => string;
  groups: string[];
  today: string;
}) {
  return (
    <div className="analysis-filters">
      <label className="analysis-filter">
        <span>Rep</span>
        <Select compact value={s.rep} onChange={(e) => set({ rep: e.target.value })}>
          <option value="">Whole team</option>
          {team.map((r) => (
            <option key={r} value={r}>
              {nameOf(r)}
            </option>
          ))}
        </Select>
      </label>
      <label className="analysis-filter">
        <span>Period</span>
        <Select
          compact
          value={s.preset}
          onChange={(e) => {
            const preset = e.target.value as Preset;
            set(
              preset === 'custom'
                ? { preset }
                : { preset, ...presetRange(preset, today), grain: suggestedGrain(preset) },
            );
          }}
        >
          {PRESETS.map((p) => (
            <option key={p.value} value={p.value}>
              {p.label}
            </option>
          ))}
        </Select>
      </label>
      {s.preset === 'custom' && (
        <>
          <label className="analysis-filter">
            <span>From</span>
            <Input compact type="date" value={s.from} max={s.to} onChange={(e) => e.target.value && set({ from: e.target.value })} />
          </label>
          <label className="analysis-filter">
            <span>To</span>
            <Input compact type="date" value={s.to} min={s.from} max={today} onChange={(e) => e.target.value && set({ to: e.target.value })} />
          </label>
        </>
      )}
      <div className="analysis-filter">
        <span>Group by</span>
        <Segmented
          ariaLabel="Group by"
          value={s.grain}
          onChange={(grain) => set({ grain })}
          options={[
            { value: 'week', label: 'Week' },
            { value: 'month', label: 'Month' },
            { value: 'quarter', label: 'Quarter' },
          ]}
        />
      </div>
      <div className="analysis-filter">
        <span>Measure</span>
        <Segmented
          ariaLabel="Measure"
          value={s.measure}
          onChange={(measure) => set({ measure })}
          options={[
            { value: 'amount', label: '₹ Amount' },
            { value: 'kg', label: 'Tonnes' },
          ]}
        />
      </div>
      <label className="analysis-filter">
        <span>Compare with</span>
        <Select compact value={s.compare} onChange={(e) => set({ compare: e.target.value as Compare })}>
          <option value="previous">Previous period</option>
          <option value="lastYear">Same period last year</option>
          <option value="none">Nothing</option>
        </Select>
      </label>
      <label className="analysis-filter">
        <span>Product</span>
        <Select compact value={s.group} onChange={(e) => set({ group: e.target.value })}>
          <option value="">All products</option>
          {groups.map((g) => (
            <option key={g} value={g}>
              {g}
            </option>
          ))}
        </Select>
      </label>
      <label className="analysis-filter">
        <span>"Gone quiet" after</span>
        <Select compact value={String(s.dormantDays)} onChange={(e) => set({ dormantDays: Number(e.target.value) })}>
          {[21, 30, 45, 60, 90].map((d) => (
            <option key={d} value={d}>
              {d} days
            </option>
          ))}
        </Select>
      </label>
    </div>
  );
}

// ---------------------------------------------------------------- KPIs ---

function Kpis({ view, s, cmpOn, reps }: { view: View; s: Settings; cmpOn: boolean; reps: View['reps'] }) {
  const { t, p, owedNow, owedBefore } = view;
  const rank = (key: 'amount' | 'kg') => {
    if (!s.rep) return undefined;
    const sorted = [...reps].sort((a, b) => b[key] - a[key]);
    return `#${sorted.findIndex((r) => r.rep === s.rep) + 1} of ${reps.length} in team`;
  };
  const tiles: Array<{ label: string; value: string; delta?: number | null; invert?: boolean; foot?: string; tone?: string }> = [
    { label: 'Sales', value: moneyShort(t.amount), delta: cmpOn ? change(t.amount, p.amount) : undefined, foot: rank('amount') ?? (cmpOn ? `was ${moneyShort(p.amount)}` : undefined) },
    { label: 'Tonnes sold', value: tonnes(t.kg), delta: cmpOn ? change(t.kg, p.kg) : undefined, foot: rank('kg') ?? (cmpOn ? `was ${tonnes(p.kg)}` : undefined) },
    { label: 'Average ₹ / kg', value: t.perKg ? `₹${t.perKg.toFixed(1)}` : '—', delta: cmpOn ? change(t.perKg, p.perKg) : undefined, foot: cmpOn && p.perKg ? `was ₹${p.perKg.toFixed(1)}` : undefined },
    { label: 'Orders', value: String(t.orders), delta: cmpOn ? change(t.orders, p.orders) : undefined, foot: t.orders ? `avg ${moneyShort(t.amount / t.orders)} each` : undefined },
    { label: 'Customers buying', value: String(t.customers), delta: cmpOn ? change(t.customers, p.customers) : undefined, foot: cmpOn ? `was ${p.customers}` : undefined },
    { label: 'Outstanding', value: moneyShort(owedNow.total), delta: owedBefore ? change(owedNow.total, owedBefore.total) : undefined, invert: true, foot: `as of ${formatDate(owedNow.end)}` },
    { label: 'Over 90 days', value: moneyShort(owedNow.d90), delta: owedBefore ? change(owedNow.d90, owedBefore.d90) : undefined, invert: true, foot: owedNow.total ? `${((owedNow.d90 / owedNow.total) * 100).toFixed(0)}% of outstanding` : undefined, tone: owedNow.d90 > 0 ? 'warn' : undefined },
    { label: 'Days of sales owed', value: `${Math.round(dso(owedNow.total, t.amount * 1.18, { from: view.buckets[0]?.start ?? '', to: owedNow.end }))} d`, foot: 'outstanding ÷ daily sales (incl. GST)' },
  ];
  return (
    <div className="tiles analysis-tiles">
      {tiles.map((k) => (
        <div key={k.label} className={`tile ${k.tone === 'warn' ? 'is-warn' : ''}`}>
          <div className="tile__label">{k.label}</div>
          <div className="tile__value">{k.value}</div>
          {k.delta !== undefined && <Delta value={k.delta} invert={k.invert} />}
          {k.foot && <div className="tile__foot">{k.foot}</div>}
        </div>
      ))}
    </div>
  );
}


// ------------------------------------------------------------ insights ---

/**
 * Plain sentences a manager would otherwise have to work out from the charts.
 * Each one is computed, never canned — if nothing notable is true, it says less.
 */
function Insights({
  view,
  s,
  nameOf,
  compareLabel,
  grain,
}: {
  view: View;
  s: Settings;
  nameOf: (id: string) => string;
  compareLabel: string;
  grain: Grain;
}) {
  const m = s.measure;
  const out: Array<{ tone: 'good' | 'bad' | 'info'; text: string }> = [];
  const { t, p, customers, owedNow, owedBefore, groups, reps } = view;

  if (Math.abs(view.slope) >= 0.01) {
    out.push({
      tone: view.slope > 0 ? 'good' : 'bad',
      text: `${m === 'amount' ? 'Sales' : 'Tonnage'} ${view.slope > 0 ? 'rising' : 'falling'} about ${Math.abs(view.slope * 100).toFixed(1)}% a ${grain} over this range.`,
    });
  }
  const ch = change(measureOf(t, m), measureOf(p, m));
  if (ch !== null && compareLabel) {
    out.push({ tone: ch >= 0 ? 'good' : 'bad', text: `${pct(ch)} against ${compareLabel.toLowerCase()} (${fmt(measureOf(p, m), m)} → ${fmt(measureOf(t, m), m)}).` });
  }
  const sorted = [...customers].sort((a, b) => measureOf(b, m) - measureOf(a, m));
  const whole = measureOf(t, m);
  if (sorted[0] && whole > 0) {
    const top3 = sorted.slice(0, 3).reduce((x, c) => x + measureOf(c, m), 0) / whole;
    if (top3 >= 0.35) {
      out.push({ tone: 'info', text: `Top 3 customers are ${(top3 * 100).toFixed(0)}% of sales — ${sorted.slice(0, 3).map((c) => c.customerName).join(', ')}.` });
    }
  }
  const lost = customers.filter((c) => c.flags.includes('lost'));
  if (lost.length) {
    const lostValue = lost.reduce((x, c) => x + measureOf(c.previous, m), 0);
    out.push({ tone: 'bad', text: `${lost.length} customer${lost.length > 1 ? 's' : ''} bought last period and nothing this period (${fmt(lostValue, m)} before): ${lost.slice(0, 4).map((c) => c.customerName).join(', ')}${lost.length > 4 ? '…' : ''}.` });
  }
  const quiet = customers.filter((c) => c.flags.includes('dormant'));
  if (quiet.length) {
    out.push({ tone: 'bad', text: `${quiet.length} customer${quiet.length > 1 ? 's have' : ' has'} not ordered in over ${s.dormantDays} days.` });
  }
  if (owedBefore && owedBefore.total > 0 && p.amount > 0) {
    const oc = change(owedNow.total, owedBefore.total)!;
    const sc = change(t.amount, p.amount)!;
    if (oc - sc > 0.1) {
      out.push({ tone: 'bad', text: `Outstanding grew ${pct(oc, 0)} while sales moved ${pct(sc, 0)} — collections are falling behind.` });
    } else if (sc - oc > 0.1) {
      out.push({ tone: 'good', text: `Outstanding moved ${pct(oc, 0)} against sales ${pct(sc, 0)} — collections are keeping up.` });
    }
  }
  if (owedNow.total > 0 && owedNow.d90 / owedNow.total >= 0.15) {
    out.push({ tone: 'bad', text: `${((owedNow.d90 / owedNow.total) * 100).toFixed(0)}% of outstanding (${moneyShort(owedNow.d90)}) is over 90 days old.` });
  }
  if (p.perKg > 0 && t.perKg > 0 && Math.abs(t.perKg - p.perKg) >= 3) {
    out.push({ tone: t.perKg > p.perKg ? 'good' : 'bad', text: `Average rate ${t.perKg > p.perKg ? 'up' : 'down'} from ₹${p.perKg.toFixed(0)} to ₹${t.perKg.toFixed(0)} a kg${groups[0] ? ` — ${groups[0].group.replace(/^FG - TRP - /, '')} is now ${(groups[0].share * 100).toFixed(0)}% of the mix` : ''}.` });
  }
  if (!s.rep && reps.length > 1) {
    const withPrev = reps.filter((r) => r.previous && measureOf(r.previous, m) > 0);
    const best = [...withPrev].sort((a, b) => (change(measureOf(b, m), measureOf(b.previous!, m)) ?? 0) - (change(measureOf(a, m), measureOf(a.previous!, m)) ?? 0));
    if (best.length >= 2) {
      const up = best[0];
      const down = best[best.length - 1];
      out.push({ tone: 'info', text: `Most improved: ${nameOf(up.rep)} (${pct(change(measureOf(up, m), measureOf(up.previous!, m)), 0)}). Biggest drop: ${nameOf(down.rep)} (${pct(change(measureOf(down, m), measureOf(down.previous!, m)), 0)}).` });
    }
  }

  if (!out.length) return null;
  return (
    <Card title="What stands out">
      <ul className="insights">
        {out.map((i, n) => (
          <li key={n} className={`insight insight--${i.tone}`}>
            <span className="insight__mark" aria-hidden>{i.tone === 'good' ? '▲' : i.tone === 'bad' ? '▼' : '●'}</span>
            {i.text}
          </li>
        ))}
      </ul>
    </Card>
  );
}

// ------------------------------------------------------------ rep table ---

function RepTable({
  reps,
  s,
  nameOf,
  colorOf,
  range,
  cmpOn,
  onPick,
}: {
  reps: View['reps'];
  s: Settings;
  nameOf: (id: string) => string;
  colorOf: (id: string) => string;
  range: Range;
  cmpOn: boolean;
  onPick: (id: string) => void;
}) {
  const m = s.measure;
  const rows = [...reps].sort((a, b) => measureOf(b, m) - measureOf(a, m));
  return (
    <div className="table-wrap analysis-table">
      <table className="table">
        <thead>
          <tr>
            <th>Rep</th>
            <th className="right">Sales</th>
            <th className="right">Tonnes</th>
            <th className="right">₹/kg</th>
            <th className="right">Orders</th>
            <th className="right">Customers</th>
            {cmpOn && <th className="right">Change</th>}
            <th className="right">Share</th>
            <th className="right">Outstanding</th>
            <th className="right">90+ days</th>
            <th className="right">Days owed</th>
            <th>Trend</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.rep} className="is-clickable" onClick={() => onPick(r.rep)}>
              <td>
                <span className="viz-swatch viz-swatch--line" style={{ background: colorOf(r.rep) }} /> {nameOf(r.rep)}
              </td>
              <td className="right num">{moneyShort(r.amount)}</td>
              <td className="right num">{tonnes(r.kg)}</td>
              <td className="right num">{r.perKg ? `₹${r.perKg.toFixed(0)}` : '—'}</td>
              <td className="right num">{r.orders}</td>
              <td className="right num">{r.customers}</td>
              {cmpOn && (
                <td className="right">
                  <Delta value={r.previous ? change(measureOf(r, m), measureOf(r.previous, m)) : null} />
                </td>
              )}
              <td className="right num">{(r.share * 100).toFixed(0)}%</td>
              <td className="right num">{moneyShort(r.outstanding)}</td>
              <td className={`right num ${r.overdue90 > 0 ? 'text-danger' : ''}`}>{moneyShort(r.overdue90)}</td>
              <td className="right num">{Math.round(dso(r.outstanding, r.amount * 1.18, range))}</td>
              <td><Sparkline values={r.spark} /></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// ------------------------------------------------------------- movement ---

function Movement({
  customers,
  flag,
  setFlag,
  cmpOn,
  dormantDays,
}: {
  customers: CustomerRow[];
  flag: FlagFilter;
  setFlag: (f: FlagFilter) => void;
  cmpOn: boolean;
  dormantDays: number;
}) {
  const count = (f: CustomerFlag) => customers.filter((c) => c.flags.includes(f)).length;
  const overdue = customers.filter((c) => (c.outstanding?.d90 ?? 0) > 0).length;
  const items: Array<{ id: FlagFilter; label: string; n: number; hint: string; tone: string }> = [
    ...(cmpOn
      ? [
          { id: 'new' as const, label: 'New customers', n: count('new'), hint: 'Bought this period, not the last', tone: 'info' },
          { id: 'lost' as const, label: 'Stopped buying', n: count('lost'), hint: 'Bought last period, nothing this one', tone: 'danger' },
          { id: 'rising' as const, label: 'Rising', n: count('rising'), hint: 'Up 20% or more', tone: 'ok' },
          { id: 'falling' as const, label: 'Falling', n: count('falling'), hint: 'Down 20% or more', tone: 'warn' },
        ]
      : []),
    { id: 'dormant', label: 'Gone quiet', n: count('dormant'), hint: `No order in ${dormantDays}+ days`, tone: 'warn' },
    { id: 'overdue', label: 'Owing 90+ days', n: overdue, hint: 'Something unpaid past 90 days', tone: 'danger' },
  ];
  return (
    <div className="movement">
      {items.map((i) => (
        <button
          key={i.id}
          type="button"
          className={`movement__item movement__item--${i.tone} ${flag === i.id ? 'is-active' : ''}`}
          onClick={() => setFlag(flag === i.id ? 'all' : i.id)}
        >
          <span className="movement__n">{i.n}</span>
          <span className="movement__label">{i.label}</span>
          <span className="movement__hint">{i.hint}</span>
        </button>
      ))}
      <div className="muted small analysis-note">Click one to list those customers below.</div>
    </div>
  );
}

// ------------------------------------------------------- customer table ---

function CustomerTable(props: {
  rows: CustomerRow[];
  s: Settings;
  nameOf: (id: string) => string;
  query: string;
  setQuery: (q: string) => void;
  flag: FlagFilter;
  setFlag: (f: FlagFilter) => void;
  sort: { key: SortKey; desc: boolean };
  setSort: (s: { key: SortKey; desc: boolean }) => void;
  showAll: boolean;
  setShowAll: (b: boolean) => void;
  open: string | null;
  setOpen: (id: string | null) => void;
  data: SampleData;
  range: Range;
  cmpRange?: Range;
  compareLabel: string;
}) {
  const { rows, s, nameOf, query, setQuery, flag, setFlag, sort, setSort, showAll, setShowAll, open, setOpen } = props;
  const m = s.measure;
  const cmpOn = !!props.cmpRange;

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    const val = (r: CustomerRow): number | string => {
      switch (sort.key) {
        case 'name': return r.customerName.toLowerCase();
        case 'value': return measureOf(r, m);
        case 'change': return change(measureOf(r, m), measureOf(r.previous, m)) ?? -Infinity;
        case 'perKg': return r.perKg;
        case 'orders': return r.orders;
        case 'last': return r.daysSinceLast ?? Infinity;
        case 'outstanding': return r.outstanding?.total ?? 0;
        case 'overdue': return r.outstanding?.d90 ?? 0;
      }
    };
    return rows
      .filter((r) => !q || r.customerName.toLowerCase().includes(q) || nameOf(r.rep).toLowerCase().includes(q))
      .filter((r) => (flag === 'all' ? true : flag === 'overdue' ? (r.outstanding?.d90 ?? 0) > 0 : r.flags.includes(flag)))
      .sort((a, b) => {
        const x = val(a);
        const y = val(b);
        const c = x < y ? -1 : x > y ? 1 : 0;
        return sort.desc ? -c : c;
      });
  }, [rows, query, flag, sort, m, nameOf]);

  const shown = showAll ? filtered : filtered.slice(0, 40);
  const th = (key: SortKey, label: string, right = true) => (
    <th
      className={`sortable ${right ? 'right' : ''} ${sort.key === key ? 'is-sorted' : ''}`}
      onClick={() => setSort({ key, desc: sort.key === key ? !sort.desc : key !== 'name' })}
      aria-sort={sort.key === key ? (sort.desc ? 'descending' : 'ascending') : undefined}
    >
      {label}
      {sort.key === key ? (sort.desc ? ' ↓' : ' ↑') : ''}
    </th>
  );

  return (
    <div>
      <div className="analysis-table-tools">
        <Input compact placeholder="Search customer or rep…" value={query} onChange={(e) => setQuery(e.target.value)} />
        {flag !== 'all' && (
          <Badge tone="accent">
            {flag === 'overdue' ? 'Owing 90+ days' : FLAG_LABEL[flag]}{' '}
            <button type="button" className="badge-x" onClick={() => setFlag('all')} aria-label="Clear filter">×</button>
          </Badge>
        )}
        <span className="muted small grow">
          {filtered.length} customer{filtered.length === 1 ? '' : 's'} · click a row for the detail
        </span>
      </div>
      <div className="table-wrap analysis-table">
        <table className="table">
          <thead>
            <tr>
              {th('name', 'Customer', false)}
              {!s.rep && <th>Rep</th>}
              {th('value', m === 'amount' ? 'Sales' : 'Tonnes')}
              <th className="right">{m === 'amount' ? 'Tonnes' : 'Sales'}</th>
              {cmpOn && th('change', 'Change')}
              {th('perKg', '₹/kg')}
              {th('orders', 'Orders')}
              {th('last', 'Last order')}
              {th('outstanding', 'Outstanding')}
              {th('overdue', '90+ days')}
              <th>Trend</th>
              <th>Notes</th>
            </tr>
          </thead>
          <tbody>
            {shown.map((r) => (
              <CustomerRowView key={r.customer} r={r} {...props} isOpen={open === r.customer} onToggle={() => setOpen(open === r.customer ? null : r.customer)} />
            ))}
          </tbody>
        </table>
        {filtered.length === 0 && <Empty title="No customers match" />}
      </div>
      {filtered.length > 40 && (
        <div className="analysis-more">
          <Button size="sm" variant="ghost" onClick={() => setShowAll(!showAll)}>
            {showAll ? 'Show the top 40' : `Show all ${filtered.length}`}
          </Button>
        </div>
      )}
    </div>
  );
}

function CustomerRowView({
  r,
  s,
  nameOf,
  isOpen,
  onToggle,
  data,
  range,
  cmpRange,
  compareLabel,
}: {
  r: CustomerRow;
  s: Settings;
  nameOf: (id: string) => string;
  isOpen: boolean;
  onToggle: () => void;
  data: SampleData;
  range: Range;
  cmpRange?: Range;
  compareLabel: string;
}) {
  const m = s.measure;
  const other = m === 'amount' ? tonnes(r.kg) : moneyShort(r.amount);
  const cols = 10 + (s.rep ? 0 : 1) + (cmpRange ? 1 : 0);
  return (
    <>
      <tr className={`is-clickable ${isOpen ? 'is-selected' : ''}`} onClick={onToggle}>
        <td className="small"><b>{r.customerName}</b></td>
        {!s.rep && <td className="small muted">{nameOf(r.rep)}</td>}
        <td className="right num">{fmt(measureOf(r, m), m)}</td>
        <td className="right num muted">{other}</td>
        {cmpRange && (
          <td className="right">
            <Delta value={change(measureOf(r, m), measureOf(r.previous, m))} />
          </td>
        )}
        <td className="right num">{r.perKg ? `₹${r.perKg.toFixed(0)}` : '—'}</td>
        <td className="right num">{r.orders}</td>
        <td className="right num small">{r.daysSinceLast === undefined ? '—' : `${r.daysSinceLast}d ago`}</td>
        <td className="right num">{r.outstanding ? moneyShort(r.outstanding.total) : '—'}</td>
        <td className={`right num ${(r.outstanding?.d90 ?? 0) > 0 ? 'text-danger' : ''}`}>
          {r.outstanding?.d90 ? moneyShort(r.outstanding.d90) : '—'}
        </td>
        <td><Sparkline values={r.spark} /></td>
        <td>
          <span className="flags">
            {r.flags.map((f) => (
              <Badge key={f} tone={FLAG_TONE[f]}>{FLAG_LABEL[f]}</Badge>
            ))}
          </span>
        </td>
      </tr>
      {isOpen && (
        <tr className="customer-detail">
          <td colSpan={cols}>
            <CustomerDetail r={r} s={s} data={data} range={range} cmpRange={cmpRange} compareLabel={compareLabel} />
          </td>
        </tr>
      )}
    </>
  );
}

function CustomerDetail({
  r,
  s,
  data,
  range,
  cmpRange,
  compareLabel,
}: {
  r: CustomerRow;
  s: Settings;
  data: SampleData;
  range: Range;
  cmpRange?: Range;
  compareLabel: string;
}) {
  const m = s.measure;
  const mine = data.lines.filter((l) => l.customer === r.customer && (!s.group || l.group === s.group));
  const buckets = bucketsBetween(range, s.grain);
  const cur = series(inRange(mine, range), buckets, s.grain);
  const prev = cmpRange ? alignedSeries(inRange(mine, cmpRange), cmpRange, s.grain, buckets.length) : [];
  const owed: OutstandingPoint[] = data.outstanding.filter((o) => o.customer === r.customer);
  const owedSeries = outstandingSeries(owed, buckets);
  const groups = byGroup(inRange(mine, range), m);
  const recent = [...inRange(mine, range)].sort((a, b) => b.date.localeCompare(a.date));
  const orders = [...new Map(recent.map((l) => [l.order, l])).values()].slice(0, 8);

  return (
    <div className="customer-detail__grid">
      <div>
        <div className="customer-detail__title">Purchases per {s.grain}</div>
        <TrendChart
          height={200}
          points={cur.map((p, i) => ({
            label: p.label,
            value: measureOf(p, m),
            compare: cmpRange ? measureOf(prev[i] ?? { amount: 0, kg: 0 }, m) : undefined,
            detail: `${p.orders} orders`,
          }))}
          format={(v) => fmt(v, m)}
          compareLabel={compareLabel}
        />
      </div>
      <div>
        <div className="customer-detail__title">Outstanding by age</div>
        <StackedBars
          height={200}
          points={owedSeries.map((o) => ({ label: o.label, parts: [o.d0_30, o.d30_60, o.d60_90, o.d90] }))}
          keys={AGE_KEYS}
          colors={AGE_COLORS}
          format={moneyShort}
        />
      </div>
      <div>
        <div className="customer-detail__title">What they buy</div>
        <HBars
          rows={groups.map((g) => ({
            id: g.group,
            label: g.group.replace(/^FG - TRP - /, ''),
            value: measureOf(g, m),
            note: `${fmt(measureOf(g, m), m)} · ₹${Math.round(g.perKg)}/kg`,
          }))}
        />
      </div>
      <div>
        <div className="customer-detail__title">Latest orders</div>
        <table className="table table--compact">
          <tbody>
            {orders.map((o) => {
              const lines = recent.filter((l) => l.order === o.order);
              return (
                <tr key={o.order}>
                  <td className="small">{formatDate(o.date)}</td>
                  <td className="right num small">{money(lines.reduce((x, l) => x + l.amount, 0))}</td>
                  <td className="right num small muted">{tonnes(lines.reduce((x, l) => x + l.kg, 0))}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// -------------------------------------------------------------- export ---

async function exportXlsx(view: View, s: Settings, range: Range, nameOf: (id: string) => string) {
  // The spreadsheet library is large; nobody needs it until they click.
  const XLSX = await import('xlsx');
  const wb = XLSX.utils.book_new();
  const add = (name: string, rows: Record<string, unknown>[]) =>
    XLSX.utils.book_append_sheet(wb, XLSX.utils.json_to_sheet(rows), name);

  add(
    'Trend',
    view.curSeries.map((p, i) => ({
      Period: p.label,
      From: p.start,
      To: p.end,
      'Sales ₹': Math.round(p.amount),
      Tonnes: +(p.kg / 1000).toFixed(3),
      Orders: p.orders,
      'Compare ₹': view.prevSeries[i] ? Math.round(view.prevSeries[i].amount) : '',
      'Compare t': view.prevSeries[i] ? +(view.prevSeries[i].kg / 1000).toFixed(3) : '',
      'Outstanding ₹': Math.round(view.owedSeries[i]?.total ?? 0),
      'Over 90 ₹': Math.round(view.owedSeries[i]?.d90 ?? 0),
    })),
  );
  add(
    'Reps',
    view.reps.map((r) => ({
      Rep: nameOf(r.rep),
      'Sales ₹': Math.round(r.amount),
      Tonnes: +(r.kg / 1000).toFixed(3),
      '₹/kg': +r.perKg.toFixed(2),
      Orders: r.orders,
      Customers: r.customers,
      'Previous ₹': r.previous ? Math.round(r.previous.amount) : '',
      'Outstanding ₹': Math.round(r.outstanding),
      'Over 90 ₹': Math.round(r.overdue90),
    })),
  );
  add(
    'Customers',
    view.customers.map((c) => ({
      Customer: c.customerName,
      Rep: nameOf(c.rep),
      'Sales ₹': Math.round(c.amount),
      Tonnes: +(c.kg / 1000).toFixed(3),
      '₹/kg': +c.perKg.toFixed(2),
      Orders: c.orders,
      'Previous ₹': Math.round(c.previous.amount),
      'Previous t': +(c.previous.kg / 1000).toFixed(3),
      'Last order': c.lastOrder ?? '',
      'Outstanding ₹': Math.round(c.outstanding?.total ?? 0),
      'Over 90 ₹': Math.round(c.outstanding?.d90 ?? 0),
      Notes: c.flags.map((f) => FLAG_LABEL[f]).join(', '),
    })),
  );
  add(
    'Products',
    view.groups.map((g) => ({ Product: g.group, 'Sales ₹': Math.round(g.amount), Tonnes: +(g.kg / 1000).toFixed(3), '₹/kg': +g.perKg.toFixed(2) })),
  );
  XLSX.writeFile(wb, `team-analysis-SAMPLE-${s.rep || 'team'}-${range.from}-to-${range.to}.xlsx`);
}
