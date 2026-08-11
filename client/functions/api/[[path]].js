/**
 * Everything under /api goes to ERPNext unchanged.
 *
 * `[[path]]` is Cloudflare's catch-all, so nested paths such as
 * `/api/resource/Sales Order/SAL-ORD-2026-00106` match too.
 */
import { proxy } from '../_proxy.js';

export const onRequest = ({ request, env }) => proxy(request, env);
