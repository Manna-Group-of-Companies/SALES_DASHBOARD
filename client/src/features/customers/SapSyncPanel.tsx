/**
 * "Reload from SAP" for credit limits.
 *
 * The mechanism — flag on a Single, on-prem poller, cooldown enforced in the
 * Server Script — is shared with the stock refresh and lives in
 * `components/common/SapRefreshPanel.tsx`. What is particular to this one is
 * the SAP company (MANNA_TREADS_LIVE), the control doc (`SAP Sync Control`)
 * and the two Server Scripts `manna_sap_request_sync` / `manna_sap_get_status`.
 */

import { Api } from '@/api/client';
import { SapRefreshPanel, type SapRefreshTarget } from '@/components/common/SapRefreshPanel';

const CREDIT: SapRefreshTarget = {
  title: 'Credit limits from SAP',
  getStatus: Api.sales.getSapSyncStatus,
  request: Api.sales.requestSapSync,
  noun: 'customer',
  busyNote: 'Fetching from SAP — about half a minute.',
};

export function SapSyncPanel() {
  return <SapRefreshPanel target={CREDIT} />;
}
