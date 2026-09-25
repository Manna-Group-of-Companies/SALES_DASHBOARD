/**
 * Rates & Dealer Prices — the Managing Director's screen (25 Sep 2026).
 *
 * Manna Treads is the master. The MD changes Manna Treads' list prices by
 * QUALITY (every item of a quality moves by the same rupees) and sets each
 * dealer's rupees off per quality; the dealers are Manna Treads' customers, so
 * their prices are Manna Treads special prices. Hi-Tech Pretreads bills Manna
 * Treads a fixed margin per kg below Manna Treads' price, so Hi-Tech's Price
 * List 01 follows, item by item, for each Manna Treads item's Hi-Tech twin.
 * Every price and discount includes GST as it stands — nothing adds or removes
 * GST.
 *
 * The screen shows every consequence before anything is saved; on Confirm it
 * saves the dealer rules in ERPNext and hands over DTW files, named for the
 * company each is imported into. SAP changes only when those files are
 * imported — nothing here writes to SAP.
 *
 * BUILT FOR THE REAL CATALOGUE. Every tab opens on summaries — one row per
 * quality, one row per dealer — and a row opens onto its detail when clicked;
 * long item lists inside are filterable and shown 25 at a time.
 *
 * What SAP holds is read from `SAP Pricing Control.snapshot_json`, refreshed by
 * "Sync from SAP" through the office server — which also checks SAP itself with
 * the PowerShell twin of the rules; the screen says if the two checks disagree.
 * The margin is `SAP Pricing Control.intercompany_margin` (kept in ERPNext, not
 * in this public code).
 *
 * History lives in SAP itself: list prices in each item's Change Log (in each
 * company), dealer prices in Manna Treads' Special Prices for Business Partners.
 *
 * The rules and the files come from `domain/dealerRates.ts`, pinned by
 * shared/fixtures/dealer_rates.json together with sap-pricing/'s PowerShell.
 */

import { useCallback, useDeferredValue, useEffect, useMemo, useRef, useState } from 'react';
import {
  buildDtwFiles,
  buildPlan,
  checkAgainstSap,
  checkCounts,
  compareServerCheck,
  diffRules,
  itemKind,
  roundMoney,
  ruleKey,
  summariseCheck,
  summariseDealers,
  summariseQualities,
  type DealerRule,
  type DtwCompany,
  type PricingSnapshot,
  type QualityChange,
} from '@/domain/dealerRates';
import { getPricingControl, listDealerRules, requestPricingSync, saveDealerRules, type PricingControl } from '@/api/pricing';
import { Alert, Badge, Button, Card, Empty, Tabs } from '@/components/ui';
import { QualitiesTab } from './QualitiesTab';
import { DealersTab } from './DealersTab';
import { PreviewTab, type Confirmed } from './PreviewTab';
import { CheckTab } from './CheckTab';
import { download, rs, stampNow, when } from './parts';
import '@/components/layout/layout.css';
import './rates.css';

type Tab = 'qualities' | 'dealers' | 'preview' | 'check';

const POLL_MS = 4_000;
const GIVE_UP_MS = 4 * 60_000;

export interface Targets {
  treads: DtwCompany;
  hitech: DtwCompany | null;
}

export function RatesPage() {
  const [control, setControl] = useState<PricingControl | null>(null);
  const [savedRules, setSavedRules] = useState<DealerRule[]>([]);
  const [draftRules, setDraftRules] = useState<DealerRule[]>([]);
  const [changeInput, setChangeInput] = useState<Record<number, string>>({});
  const [tab, setTab] = useState<Tab>('qualities');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [syncing, setSyncing] = useState<'idle' | 'waiting' | 'stalled'>('idle');
  const [syncNote, setSyncNote] = useState<string | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [confirmed, setConfirmed] = useState<Confirmed | null>(null);
  const pollTimer = useRef<number | null>(null);

  const load = useCallback(async () => {
    setError(null);
    try {
      const [c, r] = await Promise.all([getPricingControl(), listDealerRules()]);
      setControl(c);
      setSavedRules(r);
      setDraftRules(r);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : 'Could not read the rates.');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load();
    return () => {
      if (pollTimer.current) window.clearTimeout(pollTimer.current);
    };
  }, [load]);

  const snapshot: PricingSnapshot | null = control?.snapshot ?? null;
  const margin = control?.margin ?? null;

  const changes: QualityChange[] = useMemo(
    () =>
      Object.entries(changeInput)
        .map(([k, v]) => ({ propertyNo: Number(k), rupees: roundMoney(Number(v)) }))
        .filter((c) => Number.isFinite(c.rupees) && c.rupees !== 0),
    [changeInput],
  );

  // Deferred: with the real catalogue a plan is ~0.3 s (90,000 dealer prices,
  // measured 25 Sep 2026), and the MD's typing must not wait for it.
  const deferredRules = useDeferredValue(draftRules);
  const deferredChanges = useDeferredValue(changes);
  const plan = useMemo(
    () => (snapshot ? buildPlan(snapshot, deferredRules, deferredChanges, margin) : null),
    [snapshot, deferredRules, deferredChanges, margin],
  );
  const qualitySummaries = useMemo(
    () => (snapshot && plan ? summariseQualities(snapshot, plan, deferredRules, deferredChanges) : []),
    [snapshot, plan, deferredRules, deferredChanges],
  );
  const dealerSummaries = useMemo(() => (snapshot && plan ? summariseDealers(snapshot, plan, deferredRules) : []), [snapshot, plan, deferredRules]);
  const check = useMemo(() => (snapshot ? checkAgainstSap(snapshot, savedRules, margin) : null), [snapshot, savedRules, margin]);
  const checkDealers = useMemo(() => (check ? summariseCheck(check.rows) : []), [check]);
  const agreement = useMemo(
    () => (snapshot && check ? compareServerCheck(snapshot.serverCheck, checkCounts(check), savedRules, margin) : { state: 'none' as const }),
    [snapshot, check, savedRules, margin],
  );
  const ruleDiff = useMemo(() => diffRules(savedRules, draftRules), [savedRules, draftRules]);
  const ruleChanges = ruleDiff.create.length + ruleDiff.update.length + ruleDiff.remove.length;

  const customers = useMemo(() => new Map((snapshot?.customers ?? []).map((c) => [c.code, c])), [snapshot]);
  const qualities = useMemo(() => [...(snapshot?.properties ?? [])].sort((a, b) => a.no - b.no), [snapshot]);
  const targets: Targets | null = useMemo(
    () =>
      snapshot
        ? {
            treads: { db: snapshot.company, name: snapshot.companyName, priceListNo: snapshot.priceList.no },
            hitech: snapshot.hitech ? { db: snapshot.hitech.company, name: snapshot.hitech.companyName, priceListNo: snapshot.hitech.priceList.no } : null,
          }
        : null,
    [snapshot],
  );

  // ------------------------------------------------------------ sync ---

  const syncFromSap = async () => {
    if (pollTimer.current) window.clearTimeout(pollTimer.current);
    setSyncing('waiting');
    try {
      const r = await requestPricingSync();
      setSyncNote(r.message);
    } catch (e: unknown) {
      setSyncing('idle');
      setSyncNote(e instanceof Error ? e.message : 'Could not ask the office server to read SAP.');
      return;
    }
    const started = Date.now();
    const tick = async () => {
      try {
        const c = await getPricingControl();
        if (!c.syncRequested && c.status !== 'Running') {
          setControl(c);
          setSyncing('idle');
          setSyncNote(c.status === 'Success' ? `Read from SAP: ${c.lastResultMessage}` : `SAP read failed: ${c.lastResultMessage}`);
          return;
        }
      } catch {
        /* one dropped poll is not a failure */
      }
      if (Date.now() - started > GIVE_UP_MS) {
        setSyncing('stalled');
        setSyncNote(
          'The office server has not picked this up. Your request is kept and runs when it does — if this keeps happening, tell IT the pricing watcher is not running.',
        );
        return;
      }
      pollTimer.current = window.setTimeout(() => void tick(), POLL_MS);
    };
    pollTimer.current = window.setTimeout(() => void tick(), POLL_MS);
  };

  // ----------------------------------------------------------- rules ---

  const upsertRule = (r: DealerRule) =>
    setDraftRules((prev) => {
      const k = ruleKey(r);
      const i = prev.findIndex((x) => ruleKey(x) === k);
      if (i < 0) return [...prev, r];
      const next = [...prev];
      next[i] = { ...prev[i], rupeesOff: r.rupeesOff, note: r.note ?? prev[i].note };
      return next;
    });

  const removeRule = (k: string) => setDraftRules((prev) => prev.filter((x) => ruleKey(x) !== k));

  // --------------------------------------------------------- confirm ---

  const dirty = Boolean(plan && (plan.counts.listChanges || plan.counts.add || plan.counts.update || plan.counts.hitech || ruleChanges));

  const confirm = async () => {
    if (!snapshot || !targets) return;
    // From the values on screen now — not the deferred copy the preview renders,
    // which can be a keystroke behind.
    const final = buildPlan(snapshot, draftRules, changes, margin);
    const summary =
      `${final.counts.listChanges} Manna Treads list price(s), ${final.counts.add + final.counts.update} dealer price(s)` +
      (targets.hitech ? `, ${final.counts.hitech} Hi-Tech price(s)` : '') +
      (ruleChanges ? `, ${ruleChanges} dealer discount change(s) saved` : '');
    const problems = final.problems.length + final.hitechProblems.length;
    const ok = window.confirm(
      `Confirm and download the DTW files?\n\n${summary}.\n\nSAP does not change until the files are imported in DTW, each into the company its name starts with.` +
        (problems ? `\n\n${problems} row(s) have problems and are left out.` : ''),
    );
    if (!ok) return;
    setConfirming(true);
    setError(null);
    try {
      await saveDealerRules(ruleDiff);
      const files = buildDtwFiles(final, { ...targets, currency: 'INR', stamp: stampNow() });
      files.forEach((f, i) => window.setTimeout(() => download(f.name, f.content), i * 400));
      setConfirmed({ files, at: new Date().toLocaleString('en-IN'), summary });
      setChangeInput({});
      const r = await listDealerRules();
      setSavedRules(r);
      setDraftRules(r);
      setTab('preview');
    } catch (e: unknown) {
      setError(`Could not save the dealer discounts, so no files were made: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setConfirming(false);
    }
  };

  // ---------------------------------------------------------- render ---

  if (loading) {
    return (
      <div className="page">
        <Card title="Rates & Dealer Prices">Reading the rates…</Card>
      </div>
    );
  }

  const busy = control?.status === 'Running' || syncing === 'waiting';
  const dealerBad = checkDealers.reduce((n, d) => n + d.bad, 0);
  const hitechBad = check ? check.hitech.filter((r) => r.status !== 'OK').length : 0;
  const pending = plan ? plan.counts.listChanges + plan.counts.add + plan.counts.update + plan.counts.hitech : 0;
  const borrowedNames = qualities.filter((q) => q.nameFrom === 'Hi-Tech');
  const hitechName = snapshot?.hitech?.companyName ?? 'Hi-Tech Pretreads';

  return (
    <div className="page rates">
      <div className="page-head">
        <div>
          <div className="page-head__title">Rates &amp; Dealer Prices</div>
          <div className="dim small">
            {snapshot?.companyName ?? 'Manna Treads'} · SAP {snapshot?.priceList.name ?? 'Price List 01'} and dealer prices · {hitechName}'s{' '}
            {snapshot?.hitech?.priceList.name ?? 'Price List 01'} kept {margin ? `${rs(margin)}/kg` : 'the margin'} below · all prices include GST · delivered
            to SAP as DTW files
          </div>
        </div>
        <div className="rates__sync">
          <span className="small dim">
            SAP prices read <b>{when(control?.lastSyncAt ?? snapshot?.syncedAt)}</b>
          </span>
          {control && <Badge tone={control.status === 'Failed' ? 'danger' : busy ? 'info' : 'ok'}>{busy ? 'Reading SAP…' : control.status}</Badge>}
          <Button variant="primary" loading={busy} onClick={() => void syncFromSap()}>
            Sync from SAP
          </Button>
        </div>
      </div>

      {error && (
        <Alert tone="danger" title="Something went wrong">
          {error}
        </Alert>
      )}
      {syncNote && <Alert tone={syncing === 'stalled' ? 'warn' : 'info'}>{syncNote}</Alert>}
      {control?.snapshotError && (
        <Alert tone="danger" title="The SAP snapshot could not be read">
          {control.snapshotError}
        </Alert>
      )}
      {snapshot && snapshot.version < 3 && (
        <Alert tone="warn" title="This copy of SAP is from before the redesign">
          It holds Hi-Tech Pretreads' prices only. Press Sync from SAP to read Manna Treads' prices and dealers, and Hi-Tech's prices for the same
          items.
        </Alert>
      )}
      {snapshot && !margin && (
        <Alert tone="warn" title="The inter-company margin is not set">
          Hi-Tech's prices cannot be worked out until the rupees per kg Hi-Tech bills Manna Treads below its price are set in ERPNext: SAP Pricing
          Control → Hi-Tech Bills Manna Treads Less.
        </Alert>
      )}
      {agreement.state === 'disagree' && (
        <Alert tone="danger" title="The office server's check of SAP disagrees with this screen's">
          Do not import files until IT has looked: the two work out the same rules separately, and they should always agree.{' '}
          {agreement.differences.join(' · ')}.
        </Alert>
      )}
      {borrowedNames.length > 0 && (
        <Alert tone="info" title={`${borrowedNames.length} quality name(s) come from Hi-Tech's SAP`}>
          Manna Treads' SAP has not named item properties {borrowedNames.map((q) => q.no).join(', ')} yet, so Hi-Tech's names are shown (
          {borrowedNames.map((q) => q.name).join(', ')}). Name them the same in Manna Treads: Administration → Setup → Inventory → Item Properties.
        </Alert>
      )}

      {!snapshot || !targets ? (
        <Empty title="No SAP prices yet" action={<Button onClick={() => void syncFromSap()}>Sync from SAP</Button>}>
          Press Sync from SAP to read Manna Treads' prices and dealers, and Hi-Tech Pretreads' prices for the same items.
        </Empty>
      ) : (
        <>
          <div className="rates__tiles">
            <Tile label="Qualities" value={qualities.length} hint={qualities.map((q) => q.name).join(', ')} />
            <Tile
              label="Items priced"
              value={snapshot.items.length}
              hint={`${snapshot.items.filter((i) => itemKind(i) === 'Precured').length} precured · ${snapshot.items.filter((i) => itemKind(i) === 'Hot').length} hot`}
            />
            <Tile label="Dealers with discounts" value={new Set(savedRules.map((r) => r.cardCode)).size} hint={`${savedRules.length} discount(s) saved`} />
            <Tile
              label="Dealer prices in SAP"
              value={snapshot.special.length}
              hint={`${snapshot.special.filter((s) => s.priceList === 0).length} fixed · ${snapshot.special.filter((s) => s.priceList !== 0).length} percentage`}
            />
            <Tile
              label={`${hitechName} prices`}
              value={check ? check.hitech.length : 0}
              hint={`${plan?.counts.noTwin ?? 0} item(s) with no Hi-Tech twin`}
            />
            <Tile
              label="SAP check"
              value={dealerBad + hitechBad ? `${dealerBad + hitechBad} to fix` : 'All OK'}
              tone={dealerBad + hitechBad ? 'warn' : 'ok'}
              hint={`${check?.rows.length ?? 0} dealer · ${check?.hitech.length ?? 0} Hi-Tech price(s) checked${agreement.state === 'agree' ? ' · office server agrees' : ''}`}
            />
          </div>

          {dirty && plan && (
            <Alert
              tone="warn"
              title="Unconfirmed changes"
              actions={
                tab !== 'preview' ? (
                  <Button size="sm" onClick={() => setTab('preview')}>
                    Review &amp; confirm
                  </Button>
                ) : undefined
              }
            >
              {plan.counts.listChanges} Manna Treads list price(s), {plan.counts.add + plan.counts.update} dealer price(s) and {plan.counts.hitech} Hi-Tech
              price(s) would change
              {ruleChanges ? `, and ${ruleChanges} dealer discount(s)` : ''}. Nothing is saved until you confirm.
            </Alert>
          )}

          <Tabs<Tab>
            tabs={[
              { id: 'qualities', label: 'Qualities & list prices', count: changes.length || undefined },
              { id: 'dealers', label: 'Dealer discounts', count: new Set(draftRules.map((r) => r.cardCode)).size || undefined },
              { id: 'preview', label: 'Preview & confirm', count: pending || undefined },
              { id: 'check', label: 'Check against SAP', count: dealerBad + hitechBad || undefined },
            ]}
            active={tab}
            onChange={setTab}
          />

          {tab === 'qualities' && plan && (
            <QualitiesTab
              summaries={qualitySummaries}
              plan={plan}
              margin={margin}
              hitechName={hitechName}
              changeInput={changeInput}
              setChange={(no, value) => setChangeInput((p) => ({ ...p, [no]: value }))}
            />
          )}
          {tab === 'dealers' && (
            <DealersTab
              qualities={qualities}
              customers={customers}
              draftRules={draftRules}
              savedRules={savedRules}
              summaries={dealerSummaries}
              upsert={upsertRule}
              remove={removeRule}
            />
          )}
          {tab === 'preview' && plan && (
            <PreviewTab
              snapshot={snapshot}
              plan={plan}
              targets={targets}
              margin={margin}
              qualities={qualitySummaries}
              dealers={dealerSummaries}
              ruleDiff={ruleDiff}
              dirty={dirty}
              confirming={confirming}
              onConfirm={() => void confirm()}
              confirmed={confirmed}
              onSync={() => void syncFromSap()}
            />
          )}
          {tab === 'check' && check && <CheckTab dealers={checkDealers} check={check} snapshot={snapshot} margin={margin} agreement={agreement} />}

          <details className="rates__history">
            <summary>Where the history is kept (in SAP)</summary>
            <ul className="rates__notes">
              <li>
                <b>List prices:</b> in each company's SAP — Inventory → Item Master Data → open the item → Tools → Change Log. Select two versions
                and press Show Differences to see the old and new price, who changed it and when.
              </li>
              <li>
                <b>Dealer prices:</b> in Manna Treads' SAP — Inventory → Price Lists → Special Prices → Special Prices for Business Partners → the
                dealer's code. Each row is a fixed price ("Without Price List").
              </li>
              <li>
                Nothing on this screen changes SAP. Prices change in SAP only when the DTW files are imported; press Sync from SAP afterwards and the
                Check tab confirms every row.
              </li>
            </ul>
          </details>
        </>
      )}
    </div>
  );
}

function Tile({ label, value, hint, tone }: { label: string; value: number | string; hint?: string; tone?: 'ok' | 'warn' }) {
  return (
    <div className={`rates__tile ${tone ? `rates__tile--${tone}` : ''}`}>
      <div className="rates__tile-label">{label}</div>
      <div className="rates__tile-value">{value}</div>
      {hint && <div className="rates__tile-hint">{hint}</div>}
    </div>
  );
}
