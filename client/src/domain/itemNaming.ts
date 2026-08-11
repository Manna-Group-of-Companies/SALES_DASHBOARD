/**
 * Quality and pattern, parsed out of the item name.
 *
 * Neither is recorded anywhere on the site: there is no quality field, no
 * pattern field, `brand` is null on all 1,092 items and no Brand records
 * exist. They live only inside the name, in a shape the factory has used
 * consistently:
 *
 * ```
 * TREAD RUBBER PRECURED  BLACK PEARL  130  VK  90
 * └─ prefix ───────────┘ └ quality ─┘ └w┘ └p┘
 * ```
 *
 * Parsing a name is not a thing to do lightly, so the rule is deliberately
 * narrow and every failure is soft: a name that does not parse **keeps its
 * row** and loses only its place in a dropdown. Filtering out what you cannot
 * classify hides stock from the person whose job is to notice it is missing.
 */

const PREFIXES = [
  'TREAD RUBBER PRECURED ',
  'TREAD RUBBER HOT ',
  'TREAD RUBBER ',
  'PRECURED ',
  'PCTR ',
];

export interface ParsedName {
  quality?: string;
  width?: number;
  pattern?: string;
  /** True when the shape was recognised end to end. */
  parsed: boolean;
}

export const UNPARSED: ParsedName = { parsed: false };

/**
 * Normalise before parsing.
 *
 * Some names carry mojibake from an earlier import — `93Â€` and similar — so
 * anything outside the safe set becomes a space rather than being left to
 * break a token boundary silently.
 */
function normalise(name: string): string {
  return name
    .toUpperCase()
    .replace(/[^A-Z0-9 .'"/-]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/** Strip the longest matching prefix, so "TREAD RUBBER PRECURED " wins over "TREAD RUBBER ". */
function stripPrefix(s: string): string {
  let best = '';
  for (const p of PREFIXES) {
    if (s.startsWith(p) && p.length > best.length) best = p;
  }
  return best ? s.slice(best.length).trim() : s;
}

export function parseItemName(name: string): ParsedName {
  const body = stripPrefix(normalise(name || ''));
  if (!body) return UNPARSED;

  const tokens = body.split(' ');
  // The width is the first standalone number. Everything before it is the
  // quality; the token straight after it is the pattern.
  const at = tokens.findIndex((t) => /^\d+$/.test(t));
  if (at <= 0) return UNPARSED;

  const quality = tokens.slice(0, at).join(' ').trim();
  const width = Number(tokens[at]);
  const pattern = tokens[at + 1];

  // Bonding Gum and Compounded Rubber have no pattern at all — 16 items on the
  // live master. They parse to a quality and stop, which is correct.
  if (!quality) return UNPARSED;

  return { quality, width, pattern: pattern || undefined, parsed: Boolean(pattern) };
}

/** Distinct values for a dropdown, sorted, with unparsed names simply absent. */
export function distinctOf(
  names: string[],
  pick: (p: ParsedName) => string | undefined,
): string[] {
  const set = new Set<string>();
  for (const n of names) {
    const v = pick(parseItemName(n));
    if (v) set.add(v);
  }
  return [...set].sort();
}

/**
 * Whether a dropdown is worth showing.
 *
 * One value is not a choice — it is a control that can only be set to what it
 * already shows, and it costs a row of screen to say nothing.
 */
export function worthOffering(values: string[]): boolean {
  return values.length > 1;
}
