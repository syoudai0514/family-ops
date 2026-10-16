// Quick add for the shopping list: "牛乳、卵\nパン" becomes three items, and an item
// that is already on the open list is not added twice.

export function splitShoppingInput(text: string): string[] {
  const seen = new Set<string>();
  const titles: string[] = [];
  for (const part of text.split(/[\n、,，]+/u)) {
    const title = part.replace(/\s+/gu, ' ').trim();
    const key = shoppingTitleKey(title);
    if (!title || title.length > 80 || seen.has(key)) continue;
    seen.add(key);
    titles.push(title);
  }
  return titles;
}

/** Ignores width, case and spaces: "Ｔｉｓｓｕｅ" and "tissue" are the same item. */
export function shoppingTitleKey(title: string): string {
  return title.normalize('NFKC').replace(/\s+/gu, '').toLowerCase();
}
