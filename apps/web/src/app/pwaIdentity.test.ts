import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

function source(relativePath: string) {
  return readFileSync(fileURLToPath(new URL(relativePath, import.meta.url)), 'utf8');
}

describe('PWA identity', () => {
  it('uses おうちノート for the browser and iOS home-screen title', () => {
    const html = source('../../index.html');
    expect(html).toContain('<html lang="ja">');
    expect(html).toContain('<title>おうちノート</title>');
    expect(html).toContain('name="apple-mobile-web-app-title" content="おうちノート"');
    expect(html).not.toContain('<title>Family Ops</title>');
  });

  it('uses the same Japanese identity in the install manifest', () => {
    const viteConfig = source('../../vite.config.ts');
    expect(viteConfig).toContain("name: 'おうちノート'");
    expect(viteConfig).toContain("short_name: 'おうちノート'");
    expect(viteConfig).toContain("lang: 'ja'");
    expect(viteConfig).not.toContain("name: 'Family Ops'");
    expect(viteConfig).not.toContain("short_name: 'FamilyOps'");
  });
});
