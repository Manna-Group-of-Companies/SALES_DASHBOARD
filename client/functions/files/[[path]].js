/**
 * Public attachments — `/files/...`.
 *
 * Separate from `/private` because Frappe treats them differently, but both
 * must be proxied for the same reason: they are not under `/api`.
 */
import { proxy } from '../_proxy.js';

export const onRequest = ({ request, env }) => proxy(request, env);
