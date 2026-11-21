/**
 * Each manager's approval authority and the manager cap (17 Nov 2026), on the
 * Payment Commitments page. The settings live with the earlier temporary
 * credit extension (Manna Credit Extension Settings), which the payment
 * commitment ladder reads: the authority is how far over the credit limit a
 * Manager may approve with a commitment, the cap how many commitments a
 * Manager may give one customer in the window.
 */
import { useEffect, useState } from 'react';
import { getExtensionSettings, saveExtensionSettings, type ExtensionSettings } from '@/api/creditExtensions';
import { Alert, Button, Input, Modal, Skeleton } from '@/components/ui';

const rs = (v: number) => `₹${Math.round(v).toLocaleString('en-IN')}`;

/**
 * Each manager's approval authority and the manager cap. Everyone who opens
 * the page may read them, so a manager knows their own figure; only the GM may
 * change them, which the server enforces, and every change is in the
 * settings' version history.
 */
export function ApprovalAuthorityModal({ onClose }: { onClose: () => void }) {
  const [v, setV] = useState<ExtensionSettings | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState(false);
  const [def, setDef] = useState('');
  const [capCount, setCapCount] = useState('');
  const [capDays, setCapDays] = useState('');
  // Manager -> their own figure as typed; '' means "the default".
  const [own, setOwn] = useState<Record<string, string>>({});

  const load = (r: ExtensionSettings) => {
    setV(r);
    setDef(String(r.authorityPercent));
    setCapCount(String(r.capCount));
    setCapDays(String(r.capDays));
    setOwn(Object.fromEntries(r.authorities.map((a) => [a.manager, String(a.maxAmount)])));
  };
  useEffect(() => {
    getExtensionSettings()
      .then(load)
      .catch((e: unknown) => setErr(e instanceof Error && e.message ? e.message : 'Could not load.'));
  }, []);

  async function save() {
    const num = (t: string) => Number(t.replace(/,/g, ''));
    const bad = [def, capCount, capDays, ...Object.values(own).filter((t) => t.trim() !== '')].some(
      (t) => t.trim() === '' || !Number.isFinite(num(t)) || num(t) < 0,
    );
    if (bad) return setErr('Enter figures of 0 or more.');
    if (!(num(capDays) >= 1)) return setErr('The window must be at least one day.');
    setBusy(true);
    setErr(null);
    setSaved(false);
    try {
      load(
        await saveExtensionSettings({
          authorityPercent: num(def),
          capCount: Math.floor(num(capCount)),
          capDays: Math.floor(num(capDays)),
          authorities: Object.entries(own)
            .filter(([, t]) => t.trim() !== '')
            .map(([manager, t]) => ({ manager, maxAmount: num(t) })),
        }),
      );
      setSaved(true);
    } catch (e: unknown) {
      setErr(e instanceof Error && e.message ? e.message : 'Could not save.');
    } finally {
      setBusy(false);
    }
  }

  if (!v) {
    return (
      <Modal onClose={onClose} title="Approval authority">
        {err ? <Alert tone="danger">{err}</Alert> : <Skeleton height={120} />}
      </Modal>
    );
  }
  const edit = v.canEdit;
  return (
    <Modal onClose={onClose} title="Approval authority">
      <div className="tiny dim">
        A manager approves extra credit up to their authority, with a payment commitment of at most {v.maxDays} days, and at most{' '}
        {v.capCount} extension(s) for one customer in {v.capDays} days. Anything past that goes to the GM.
        {v.myAuthority !== null &&
          (v.myOwnAuthority !== null
            ? ` Your authority: ${rs(v.myOwnAuthority)}.`
            : ` Your authority: ${v.authorityPercent}% of the order.`)}
      </div>
      {err && <Alert tone="danger">{err}</Alert>}
      {saved && <Alert tone="ok">Saved.</Alert>}
      <label className="tiny dim" style={{ marginTop: 10, display: 'block' }}>
        Every manager&apos;s authority, unless set below: how far over the credit limit they may approve, as a % of
        the order (0 = none)
      </label>
      <Input value={def} onChange={(e) => setDef(e.target.value)} inputMode="decimal" disabled={!edit || busy} />
      <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
        <div className="grow">
          <label className="tiny dim">Manager extensions per customer</label>
          <Input value={capCount} onChange={(e) => setCapCount(e.target.value)} inputMode="numeric" disabled={!edit || busy} />
        </div>
        <div className="grow">
          <label className="tiny dim">in this many days</label>
          <Input value={capDays} onChange={(e) => setCapDays(e.target.value)} inputMode="numeric" disabled={!edit || busy} />
        </div>
      </div>
      {v.managers.length > 0 && (
        <table className="table" style={{ marginTop: 10 }}>
          <thead>
            <tr>
              <th>Manager</th>
              <th>Team</th>
              <th>{edit ? 'Own authority (blank = the default)' : 'Authority'}</th>
            </tr>
          </thead>
          <tbody>
            {v.managers.map((m) => (
              <tr key={m.user}>
                <td>{m.name}</td>
                <td>{m.team}</td>
                <td>
                  {edit ? (
                    <Input
                      value={own[m.user] ?? ''}
                      onChange={(e) => setOwn((o) => ({ ...o, [m.user]: e.target.value }))}
                      inputMode="decimal"
                      placeholder={`default ${Number(def.replace(/,/g, '')) || 0}% of the order`}
                      disabled={busy}
                    />
                  ) : (
                    m.own !== null ? rs(m.own) : `${v.authorityPercent}% of the order`
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {edit && (
        <div className="ir-actions">
          <Button variant="primary" onClick={save} loading={busy}>
            Save
          </Button>
        </div>
      )}
    </Modal>
  );
}
