/**
 * Download the current view as an Excel file.
 *
 * The rows are built lazily, by callback, so a report that nobody exports
 * never pays for the mapping — and `xlsx` itself is `import()`ed on click. It
 * is the largest dependency in the project (430 kB), and loading it eagerly
 * would put it in the main bundle for every user who never presses this.
 *
 * What is exported is what is on screen: the same filtered, corrected figures,
 * not a second query that could quietly disagree with the table above it.
 */

import { useState } from 'react';
import { Button } from '@/components/ui';

export type SheetRow = Record<string, string | number | null | undefined>;

export function ExportButton({
  filename,
  sheet,
  rows,
  disabled = false,
  label = 'Excel',
}: {
  filename: string;
  sheet: string;
  rows: () => SheetRow[];
  disabled?: boolean;
  label?: string;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const download = async () => {
    setBusy(true);
    setError(null);
    try {
      const data = rows();
      if (!data.length) {
        setError('Nothing to export');
        return;
      }
      const XLSX = await import('xlsx');
      const ws = XLSX.utils.json_to_sheet(data);

      // Size each column to its widest cell, header included — the default is
      // 8 characters, which truncates every date and name in the sheet.
      const headers = Object.keys(data[0]!);
      ws['!cols'] = headers.map((h) => ({
        wch: Math.min(
          40,
          Math.max(h.length, ...data.map((r) => String(r[h] ?? '').length)) + 2,
        ),
      }));

      const wb = XLSX.utils.book_new();
      XLSX.utils.book_append_sheet(wb, ws, sheet.slice(0, 31));
      XLSX.writeFile(wb, filename);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not build the file');
    } finally {
      setBusy(false);
    }
  };

  return (
    <Button
      size="sm"
      variant="ghost"
      onClick={download}
      loading={busy}
      disabled={disabled || busy}
      title={error ?? 'Download this view as an Excel file'}
    >
      <span aria-hidden>⤓</span> {error ?? label}
    </Button>
  );
}
