/**
 * Session-gated attachments — odometer photos, expense bills, shop fronts.
 *
 * Frappe serves these from `/private/files/...`, outside `/api`. Without this
 * route an <img> pointing at a photo is answered by the static site, 404s, and
 * degrades to a broken image with nothing in the console to explain it.
 */
import { proxy } from '../_proxy.js';

export const onRequest = ({ request, env }) => proxy(request, env);
