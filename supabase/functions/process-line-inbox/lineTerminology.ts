export type ConfirmedHouseholdTerm = { phrase: string; meaning: string };

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Applies only explicit household language mappings; it cannot affect rules.
 *
 * Replacement is deliberately single-pass. A mapped meaning is parser input,
 * not fresh user text, so it must never be reinterpreted by a shorter mapping
 * that happens to occur inside the meaning produced by a longer mapping.
 */
export function applyConfirmedTerminology(text: string, terms: readonly ConfirmedHouseholdTerm[]): string {
  const normalized = text.normalize('NFKC');
  const replacements = new Map<string, string>();

  for (const term of terms) {
    const phrase = term.phrase.trim().normalize('NFKC');
    const meaning = term.meaning.trim().normalize('NFKC');
    if (!phrase || !meaning || phrase === meaning || replacements.has(phrase)) continue;
    replacements.set(phrase, meaning);
  }

  const phrases = [...replacements.keys()].sort((a, b) => b.length - a.length);
  if (phrases.length === 0) return normalized;

  const pattern = new RegExp(phrases.map(escapeRegExp).join('|'), 'gu');
  return normalized.replace(pattern, (matched) => replacements.get(matched) ?? matched);
}
