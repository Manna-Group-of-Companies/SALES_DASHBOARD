/**
 * Rates & Dealer Prices — the Managing Director's screen (25 Sep 2026).
 *
 * Manna Treads is the master. The groups are SAP's item properties, which the
 * user names "Type - Quality" in both companies ("HOT - Black Pearl", "PCTR -
 * Black Pearl"; a new one such as "BONDING GUM - Black Pearl" appears as a new
 * group by itself). The MD changes Manna Treads' list price per group — every
 * item carrying the property moves by the same rupees — and sets each
 * dealer's rupees off per group; the dealers are Manna Treads' customers, so
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
 * KEPT PLAIN (the user, 26 Sep 2026): the heading, when SAP was last read and
 * Sync from SAP, then the tabs — no summary tiles, sub-headings or notes. A
 * banner appears only when something needs the MD: an error, a sync that
 * failed or went unanswered, unconfirmed changes, files waiting for import,
 * or the office server's check disagreeing with this one.
 *
 * BUILT FOR THE REAL CATALOGUE. Each tab is one row per group or dealer that
 * opens onto its detail when clicked; long item lists inside are filterable
 * and shown 25 at a time.
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
  badRules,
  checkCounts,
  compareServerCheck,
  diffRules,
  staleRules,
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
import { Alert, Button, Card, Empty, Tabs } from '@/components/ui';
import { QualitiesTab } from './QualitiesTab';
import { DealersTab } from './DealersTab';
import { PreviewTab, type Confirmed } from './PreviewTab';
import { CheckTab } from './CheckTab';
import { stampNow, when } from './parts';
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
  /** Rupees typed per group, keyed by the item property's number. */
  const [changeInput, setChangeInput] = useState<Record<string, string>>({});
  const [tab, setTab] = useState<Tab>('qualities');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [syncing, setSyncing] = useState<'idle' | 'waiting' | 'stalled'>('idle');
  /** Only what the header's time cannot say: a failure, a wait, cleared boxes. */
  const [syncNote, setSyncNote] = useState<{ tone: 'info' | 'warn' | 'danger'; text: string } | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [confirmed, setConfirmed] = useState<Confirmed | null>(null);
  const confirmedRef = useRef<Confirmed | null>(null);
  confirmedRef.current = confirmed;
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
        .map(([k, v]): QualityChange => ({ propertyNo: Number(k), rupees: roundMoney(Number(v)) }))
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
  const itemCounts = useMemo(() => new Map(qualitySummaries.map((q) => [q.propertyNo, q.items.length])), [qualitySummaries]);
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
    setSyncNote(null);
    try {
      const r = await requestPricingSync();
      // Otherwise the spinning button says it; a cooldown is a wait worth naming.
      if (r.afterCooldown) setSyncNote({ tone: 'info', text: r.message });
    } catch (e: unknown) {
      setSyncing('idle');
      setSyncNote({ tone: 'danger', text: e instanceof Error ? e.message : 'Could not ask the office server to read SAP.' });
      return;
    }
    const started = Date.now();
    const tick = async () => {
      try {
        const c = await getPricingControl();
        if (!c.syncRequested && c.status !== 'Running') {
          setControl(c);
          setSyncing('idle');
          // Files were made from the previous copy of SAP. This one may already
          // hold them, so the list changes that went into them are cleared
          // rather than applied a second time on top of the imported prices.
          const fresh = Boolean(confirmedRef.current && c.snapshot && c.snapshot.syncedAt !== confirmedRef.current.syncedAt);
          if (fresh) setChangeInput({});
          // A success shows as the new time in the header.
          if (c.status !== 'Success') setSyncNote({ tone: 'danger', text: `SAP read failed: ${c.lastResultMessage}` });
          else setSyncNote(fresh ? { tone: 'info', text: 'List-price changes cleared after the new SAP read.' } : null);
          return;
        }
      } catch {
        /* one dropped poll is not a failure */
      }
      if (Date.now() - started > GIVE_UP_MS) {
        setSyncing('stalled');
        setSyncNote({
          tone: 'warn',
          text: 'The office server has not responded. The sync stays queued; contact IT if this persists.',
        });
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
      next[i] = { ...prev[i], rupeesOff: r.rupeesOff, note: r.note ?? prev[i].note, quality: r.quality || prev[i].quality };
      return next;
    });

  const removeRule = (k: string) => setDraftRules((prev) => prev.filter((x) => ruleKey(x) !== k));

  // --------------------------------------------------------- confirm ---

  const dirty = Boolean(plan && (plan.counts.listChanges || plan.counts.add || plan.counts.update || plan.counts.hitech || ruleChanges));
  /**
   * Files have been made from THIS copy of SAP and it has not been read again
   * since. Until it is, the plan still shows what went into the files as
   * pending — rightly, SAP does not have it yet — but confirming again would
   * only make the same files over, so the screen says "import, then Sync".
   */
  const awaitingImport = Boolean(confirmed && snapshot && confirmed.syncedAt === snapshot.syncedAt);
  const stale = useMemo(() => (snapshot ? staleRules(snapshot, savedRules) : []), [snapshot, savedRules]);

  const confirm = async () => {
    if (!snapshot || !targets) return;
    const bad = badRules(draftRules);
    if (bad.length) {
      setError(
        `₹/kg off must be more than ₹0 — fix ${bad.map((r) => `${r.cardName || r.cardCode} on ${r.quality || `property ${r.propertyNo}`}`).join(', ')} on the Dealer prices tab. Nothing was saved.`,
      );
      return;
    }
    // From the values on screen now — not the deferred copy the preview renders,
    // which can be a keystroke behind.
    const final = buildPlan(snapshot, draftRules, changes, margin);
    // Every rule saved now carries its group's name as SAP has it today, so
    // ERPNext reads "Hot - Black Pearl" even for a rule made before the rename.
    const names = new Map(snapshot.properties.map((p) => [p.no, p.name]));
    const diff = diffRules(savedRules, draftRules, names);
    const saving = diff.create.length + diff.update.length + diff.remove.length;
    const summary =
      `${final.counts.listChanges} Manna Treads list price(s), ${final.counts.add + final.counts.update} dealer price(s)` +
      (targets.hitech ? `, ${final.counts.hitech} Hi-Tech price(s)` : '') +
      (saving ? `, ${saving} dealer price rule change(s) saved` : '');
    const problems = final.problems.length + final.hitechProblems.length;
    const ok = window.confirm(
      `${awaitingImport ? 'Make the files again? The earlier files are replaced.\n\n' : ''}Confirm and make the DTW files?\n\n${summary}.\n\nSAP changes only when the files are imported in DTW.` +
        (problems ? `\n\n${problems} row(s) have problems and are left out.` : ''),
    );
    if (!ok) return;
    setConfirming(true);
    setError(null);
    try {
      await saveDealerRules(diff);
    } catch (e: unknown) {
      setError(`Could not save the dealer prices, so no files were made: ${e instanceof Error ? e.message : String(e)}`);
      setConfirming(false);
      return;
    }
    // No automatic downloads: a browser lets a page start one per click and
    // blocks the rest, which is how six files once arrived as one. Each of the
    // (at most three) files gets its own button on the Preview tab. The list
    // changes stay in their boxes until SAP is read again (see awaitingImport).
    const files = buildDtwFiles(final, { ...targets, currency: 'INR', stamp: stampNow() });
    setConfirmed({ files, at: new Date().toLocaleString('en-IN'), summary, syncedAt: snapshot.syncedAt, downloaded: {} });
    setTab('preview');
    try {
      const r = await listDealerRules();
      setSavedRules(r);
      setDraftRules(r);
    } catch (e: unknown) {
      setError(
        `Dealer prices saved and files ready, but they could not be read back (${e instanceof Error ? e.message : String(e)}). Reload the page before making further changes.`,
      );
    } finally {
      setConfirming(false);
    }
  };

  const markDownloaded = (name: string) =>
    setConfirmed((c) => (c ? { ...c, downloaded: { ...c.downloaded, [name]: true } } : c));

  // ---------------------------------------------------------- render ---

  if (loading) {
    return (
      <div className="page">
        <Card title="Rates & Dealer Prices">Loading…</Card>
      </div>
    );
  }

  const busy = control?.status === 'Running' || syncing === 'waiting';
  const failed = !busy && control?.status === 'Failed';
  const dealerBad = checkDealers.reduce((n, d) => n + d.bad, 0);
  const hitechBad = check ? check.hitech.filter((r) => r.status !== 'OK').length : 0;
  const pending = plan ? plan.counts.listChanges + plan.counts.add + plan.counts.update + plan.counts.hitech : 0;
  const hitechName = snapshot?.hitech?.companyName ?? 'Hi-Tech Pretreads';

  return (
    <div className="page rates">
      <div className="page-head rates__head">
        <div className="page-head__title grow">Rates &amp; Dealer Prices</div>
        <div className="rates__sync">
          <div className={`rates__synced${failed ? ' rates__synced--failed' : ''}`} title={failed ? control?.lastResultMessage : undefined}>
            <span className="rates__synced-label">{busy ? 'Reading SAP…' : failed ? 'Last SAP sync failed' : 'Last SAP sync'}</span>
            <span className="rates__synced-at">{when(control?.lastSyncAt ?? snapshot?.syncedAt)}</span>
          </div>
          <Button variant="primary" loading={busy} onClick={() => void syncFromSap()}>
            Sync from SAP
          </Button>
        </div>
      </div>

      {error && (
        <Alert tone="danger" title="Error">
          {error}
        </Alert>
      )}
      {syncNote && <Alert tone={syncNote.tone}>{syncNote.text}</Alert>}
      {control?.snapshotError && (
        <Alert tone="danger" title="SAP data could not be read">
          {control.snapshotError}
        </Alert>
      )}
      {snapshot && snapshot.version < 3 && <Alert tone="warn" title="SAP data out of date — sync from SAP" />}
      {snapshot && !margin && (
        <Alert tone="warn" title="Inter-company margin not set">
          ERPNext: SAP Pricing Control → Hi-Tech Bills Manna Treads Less.
        </Alert>
      )}
      {agreement.state === 'disagree' && (
        <Alert tone="danger" title="Office server check disagrees">
          Do not import files until IT has reviewed. {agreement.differences.join(' · ')}.
        </Alert>
      )}

      {!snapshot || !targets ? (
        <Empty title="No SAP prices" action={<Button onClick={() => void syncFromSap()}>Sync from SAP</Button>} />
      ) : (
        <>
          {awaitingImport && confirmed && (
            <Alert
              tone="info"
              title={`Files made ${confirmed.at} · awaiting DTW import`}
              actions={
                tab !== 'preview' ? (
                  <Button size="sm" onClick={() => setTab('preview')}>
                    View files
                  </Button>
                ) : undefined
              }
            >
              Import them, then Sync from SAP.
            </Alert>
          )}
          {dirty && plan && !awaitingImport && (
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
              Nothing is saved until confirmed.
            </Alert>
          )}

          <Tabs<Tab>
            tabs={[
              { id: 'qualities', label: 'List prices', count: changes.length || undefined },
              { id: 'dealers', label: 'Dealer prices', count: new Set(draftRules.map((r) => r.cardCode)).size || undefined },
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
              hitechName={hitechName}
              changeInput={changeInput}
              setChange={(no, value) => setChangeInput((p) => ({ ...p, [no]: value }))}
            />
          )}
          {tab === 'dealers' && (
            <DealersTab
              qualities={qualities}
              itemCounts={itemCounts}
              customers={customers}
              draftRules={draftRules}
              savedRules={savedRules}
              summaries={dealerSummaries}
              stale={stale}
              upsert={upsertRule}
              remove={removeRule}
            />
          )}
          {tab === 'preview' && plan && (
            <PreviewTab
              snapshot={snapshot}
              plan={plan}
              targets={targets}
              qualities={qualitySummaries}
              dealers={dealerSummaries}
              ruleDiff={ruleDiff}
              dirty={dirty}
              awaitingImport={awaitingImport}
              confirming={confirming}
              onConfirm={() => void confirm()}
              confirmed={confirmed}
              onDownloaded={markDownloaded}
              onSync={() => void syncFromSap()}
            />
          )}
          {tab === 'check' && check && <CheckTab dealers={checkDealers} check={check} snapshot={snapshot} agreement={agreement} />}
        </>
      )}
    </div>
  );
}
