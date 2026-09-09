import { describe, expect, it } from 'vitest';
import html from '../../index.html?raw';
import viteConfig from '../../vite.config.ts?raw';

describe('PWA identity', () => {
  it('uses おうちノート for the browser and iOS home-screen title', () => {
    expect(html).toContain('<html lang="ja">');
    expect(html).toContain('<title>おうちノート</title>');
    expect(html).toContain('name="apple-mobile-web-app-title" content="おうちノート"');
    expect(html).not.toContain('<title>Family Ops</title>');
  });

  it('uses the same Japanese identity in the install manifest', () => {
    expect(viteConfig).toContain("name: 'おうちノート'");
    expect(viteConfig).toContain("short_name: 'おうちノート'");
    expect(viteConfig).toContain("lang: 'ja'");
    expect(viteConfig).not.toContain("name: 'Family Ops'");
    expect(viteConfig).not.toContain("short_name: 'FamilyOps'");
  });
});
