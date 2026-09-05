export type ConfirmedHouseholdTerm = { phrase: string; meaning: string };

/** Applies only explicit household language mappings; it cannot affect rules. */
export function applyConfirmedTerminology(text: string, terms: readonly ConfirmedHouseholdTerm[]): string {
  let result = text.normalize('NFKC');
  const safeTerms = terms.filter((term) => term.phrase.trim() && term.meaning.trim())
    .sort((a, b) => b.phrase.length - a.phrase.length);
  for (const term of safeTerms) {
    const phrase = term.phrase.normalize('NFKC');
    const meaning = term.meaning.normalize('NFKC');
    if (phrase !== meaning) result = result.split(phrase).join(meaning);
  }
  return result;
}
