/**
 * Excel import for the product master and customer GST/address details
 * (1.1, 1.3).
 *
 * Deliberately a three-step flow — drop, review, commit — because a bad product
 * sheet silently imported is worse than no sheet at all: a PCTR row with no
 * average roll weight cannot price an order. Rows that fail validation are
 * listed with their Excel row number and are never committed; the good rows
 * still go in.
 */

import { useRef, useState } from 'react';
import type { Customer, Product } from '@/domain/types';
import { CATEGORY_LABEL } from '@/domain/types';
import { rollWeight } from '@/domain/productRules';
import { Api, type ImportKind, type ParseResult, type RowIssue } from '@/api/client';
import { useAppDispatch, useAppSelector } from '@/store/hooks';
import { loadCatalog } from '@/store/slices/catalogSlice';
import { pushToast } from '@/store/slices/notificationsSlice';
import { selectUser } from '@/store/selectors';
import { Alert, Badge, Button, Card, Empty, Segmented } from '@/components/ui';
import './import.css';

type AnyResult = ParseResult<Product> | ParseResult<Customer>;

export function ImportPage() {
  const dispatch = useAppDispatch();
  const user = useAppSelector(selectUser);
  const fileInput = useRef<HTMLInputElement>(null);

  const [kind, setKind] = useState<ImportKind>('products');
  const [result, setResult] = useState<AnyResult | null>(null);
  const [fileName, setFileName] = useState('');
  const [busy, setBusy] = useState(false);
  const [dragging, setDragging] = useState(false);

  const handleFile = async (file: File) => {
    setBusy(true);
    setFileName(file.name);
    try {
      const buffer = await file.arrayBuffer();
      setResult(
        kind === 'products'
          ? await Api.importer.parseProducts(buffer)
          : await Api.importer.parseCustomers(buffer),
      );
    } catch {
      dispatch(pushToast('That file could not be read as a spreadsheet.', 'critical'));
      setResult(null);
    } finally {
      setBusy(false);
    }
  };

  const commit = async () => {
    if (!result) return;
    setBusy(true);
    try {
      const summary =
        result.kind === 'products'
          ? await Api.importer.commitProducts(result.valid as Product[])
          : await Api.importer.commitCustomers(result.valid as Customer[]);
      dispatch(
        pushToast(
          `${summary.created} created, ${summary.updated} updated from ${fileName}.`,
          'success',
        ),
      );
      void dispatch(loadCatalog(user?.salesPerson));
      reset();
    } finally {
      setBusy(false);
    }
  };

  const reset = () => {
    setResult(null);
    setFileName('');
    if (fileInput.current) fileInput.current.value = '';
  };

  return (
    <div>
      <div className="page-head">
        <div className="grow">
          <div className="page-head__title">Data import</div>
          <div className="page-head__sub">
            Load the product master and customer GST/address details from Excel
          </div>
        </div>
        <Segmented
          ariaLabel="What to import"
          value={kind}
          onChange={(v) => {
            setKind(v);
            reset();
          }}
          options={[
            { value: 'products', label: 'Products' },
            { value: 'customers', label: 'Customers' },
          ]}
        />
      </div>

      {!result ? (
        <div className="cols cols--sidebar">
          <Card>
            <div
              className={`dropzone ${dragging ? 'is-dragging' : ''}`}
              onDragOver={(e) => {
                e.preventDefault();
                setDragging(true);
              }}
              onDragLeave={() => setDragging(false)}
              onDrop={(e) => {
                e.preventDefault();
                setDragging(false);
                const file = e.dataTransfer.files[0];
                if (file) void handleFile(file);
              }}
              onClick={() => fileInput.current?.click()}
              role="button"
              tabIndex={0}
              onKeyDown={(e) => {
                if (e.key === 'Enter') fileInput.current?.click();
              }}
            >
              <div className="dropzone__icon" aria-hidden>
                ⬆
              </div>
              <div className="dropzone__title">
                Drop the {kind === 'products' ? 'product' : 'customer'} sheet here
              </div>
              <div className="small muted">or click to choose a .xlsx / .xls / .csv file</div>
              {busy && <div className="small" style={{ marginTop: 8 }}>Reading…</div>}
              <input
                ref={fileInput}
                type="file"
                accept=".xlsx,.xls,.csv"
                hidden
                onChange={(e) => {
                  const file = e.target.files?.[0];
                  if (file) void handleFile(file);
                }}
              />
            </div>
          </Card>

          <Card title="Expected columns">
            <p className="small muted" style={{ marginBottom: 10 }}>
              Column names are matched loosely — case, spacing and common synonyms are all handled.
            </p>
            {kind === 'products' ? (
              <ul className="col-list">
                <li><b>Item Code</b>, <b>Item Name</b>, <b>Category</b> — required on every row</li>
                <li>Category accepts PCTR / CTR / BG / VS or the full name</li>
                <li>
                  <b>Avg Weight Per Roll</b> + <b>Belts Per Roll</b> — required for PCTR.
                  Despite its name, that column holds the weight of one <b>belt</b>;
                  the roll weight is the two multiplied together.
                </li>
                <li><b>Weight Per Roll</b> — required for CTR</li>
                <li><b>Tin Size</b> — must be 10 or 30 for VS</li>
                <li>Rate, Size, HSN Code — optional</li>
              </ul>
            ) : (
              <ul className="col-list">
                <li><b>Customer Name</b> — required</li>
                <li><b>Address</b> and <b>GSTIN</b> — required, they print on the proforma</li>
                <li>GSTIN is checked against the 15-character format</li>
                <li>Destination, State, Phone, Email, Credit Limit, Reps — optional</li>
              </ul>
            )}
            <Button
              size="sm"
              block
              style={{ marginTop: 12 }}
              onClick={() => void Api.importer.downloadTemplate(kind)}
            >
              Download blank template
            </Button>
          </Card>
        </div>
      ) : (
        <ReviewStep
          result={result}
          fileName={fileName}
          busy={busy}
          onCancel={reset}
          onCommit={() => void commit()}
        />
      )}
    </div>
  );
}

function ReviewStep({
  result,
  fileName,
  busy,
  onCancel,
  onCommit,
}: {
  result: AnyResult;
  fileName: string;
  busy: boolean;
  onCancel: () => void;
  onCommit: () => void;
}) {
  const rejected = new Set(result.issues.map((i) => i.row)).size;

  return (
    <div className="stack gap-4">
      <div className="tiles">
        <Tile label="Rows in file" value={result.totalRows} />
        <Tile label="Ready to import" value={result.valid.length} tone="ok" />
        <Tile label="Rejected rows" value={rejected} tone={rejected ? 'alert' : undefined} />
        <Tile label="Problems found" value={result.issues.length} tone={result.issues.length ? 'warn' : undefined} />
      </div>

      {result.issues.length > 0 && (
        <Alert tone="warn" title={`${rejected} row${rejected === 1 ? '' : 's'} will be skipped`}>
          The rows below are missing something the app needs. Fix them in the sheet and re-import —
          everything else can be committed now.
        </Alert>
      )}

      <div className="cols cols--sidebar">
        <Card title={`Preview — ${fileName}`} flush>
          {result.valid.length === 0 ? (
            <Empty icon="⚠" title="Nothing importable">
              Every row had a problem. Fix the sheet and try again.
            </Empty>
          ) : (
            <div className="table-wrap" style={{ maxHeight: 460 }}>
              {result.kind === 'products' ? (
                <ProductPreview rows={result.valid as Product[]} />
              ) : (
                <CustomerPreview rows={result.valid as Customer[]} />
              )}
            </div>
          )}
        </Card>

        <Card title={`Problems (${result.issues.length})`} flush>
          {result.issues.length === 0 ? (
            <Empty icon="✓" title="No problems" />
          ) : (
            <div style={{ maxHeight: 460, overflowY: 'auto' }}>
              {result.issues.map((issue, i) => (
                <IssueRow key={`${issue.row}-${issue.column}-${i}`} issue={issue} />
              ))}
            </div>
          )}
        </Card>
      </div>

      <div className="row gap-2" style={{ justifyContent: 'flex-end' }}>
        <Button onClick={onCancel}>Choose a different file</Button>
        <Button
          variant="primary"
          loading={busy}
          disabled={result.valid.length === 0}
          onClick={onCommit}
        >
          Import {result.valid.length} row{result.valid.length === 1 ? '' : 's'}
        </Button>
      </div>
    </div>
  );
}

function ProductPreview({ rows }: { rows: Product[] }) {
  return (
    <table className="table">
      <thead>
        <tr>
          <th>Code</th>
          <th>Name</th>
          <th>Category</th>
          <th className="right">Roll weight</th>
          <th className="right">Belts/roll</th>
          <th className="right">Tin</th>
          <th className="right">Rate</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((p) => (
          <tr key={p.code}>
            <td className="mono small">{p.code}</td>
            <td className="small">{p.name}</td>
            <td>
              <Badge tone="accent">{p.category}</Badge>
              <div className="tiny dim">{CATEGORY_LABEL[p.category]}</div>
            </td>
            <td className="right num">
              {rollWeight(p)
                ? `${rollWeight(p)} kg${p.category === 'PCTR' ? ' (avg)' : ''}`
                : '—'}
            </td>
            <td className="right num">{p.beltsPerRoll ?? '—'}</td>
            <td className="right num">{p.tinSize ? `${p.tinSize}L` : '—'}</td>
            <td className="right num">{p.defaultRate ?? '—'}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function CustomerPreview({ rows }: { rows: Customer[] }) {
  return (
    <table className="table">
      <thead>
        <tr>
          <th>Name</th>
          <th>Destination</th>
          <th>GSTIN</th>
          <th>State</th>
          <th className="right">Credit limit</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((c) => (
          <tr key={c.id}>
            <td>
              <div className="small strong">{c.name}</div>
              <div className="tiny dim">{c.address}</div>
            </td>
            <td className="small">{c.destination}</td>
            <td className="mono small">{c.gstin}</td>
            <td className="small">{c.state || '—'}</td>
            <td className="right num">{c.creditLimit || '—'}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function IssueRow({ issue }: { issue: RowIssue }) {
  return (
    <div className="issue">
      <span className="issue__row">Row {issue.row}</span>
      <div className="grow">
        <div className="small strong">{issue.column}</div>
        <div className="tiny muted">{issue.message}</div>
      </div>
    </div>
  );
}

function Tile({
  label,
  value,
  tone,
}: {
  label: string;
  value: number;
  tone?: 'ok' | 'warn' | 'alert';
}) {
  return (
    <div className={`tile ${tone === 'alert' ? 'is-alert' : tone === 'warn' ? 'is-warn' : ''}`}>
      <div className="tile__label">{label}</div>
      <div className="tile__value" style={{ color: tone === 'ok' ? 'var(--ok)' : undefined }}>
        {value}
      </div>
    </div>
  );
}
