/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_USE_MOCK?: string;
  readonly VITE_ERP_URL?: string;
  readonly VITE_MIN_STOCK_POLL_MS?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
