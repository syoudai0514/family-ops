/// <reference types="vitest/config" />
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';

// https://vite.dev/config/
export default defineConfig({
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['favicon.svg'],
      manifest: {
        name: 'Family Ops',
        short_name: 'FamilyOps',
        description: '家族の予定・家事・お願い・買い物・引き継ぎを共有する家庭運営OS',
        theme_color: '#16171d',
        background_color: '#16171d',
        display: 'standalone',
        start_url: '/',
        scope: '/',
        icons: [
          { src: '/pwa-192.png', sizes: '192x192', type: 'image/png' },
          { src: '/pwa-512.png', sizes: '512x512', type: 'image/png' },
          {
            src: '/pwa-maskable-512.png',
            sizes: '512x512',
            type: 'image/png',
            purpose: 'maskable',
          },
        ],
      },
      workbox: {
        // Read-only offline caching for the app shell only. Mutations require
        // network + Edge Functions, so no mutation requests are cached.
        globPatterns: ['**/*.{js,css,html,svg,png,ico}'],
        runtimeCaching: [
          {
            // Supabase PostgREST reads (every `supabase.from(...).select(...)`
            // call in this app, e.g. Today, Requests, Shopping, Handovers).
            // NetworkFirst: always prefer a fresh read when online, but fall
            // back to the last-cached response so a previously-loaded screen
            // (most importantly Today) still renders read-only while offline.
            // Deliberately scoped to GET only, and to /rest/v1/ specifically —
            // POST mutations to /functions/v1/* must never be cached or
            // served from cache, so they are simply not matched by any rule
            // here and fall straight through to the network as normal.
            urlPattern: ({ url, request }) =>
              request.method === 'GET' && url.pathname.startsWith('/rest/v1/'),
            handler: 'NetworkFirst',
            method: 'GET',
            options: {
              cacheName: 'supabase-rest-reads',
              networkTimeoutSeconds: 4,
              expiration: { maxEntries: 200, maxAgeSeconds: 60 * 60 * 24 },
              cacheableResponse: { statuses: [0, 200] },
            },
          },
        ],
      },
    }),
  ],
  test: {
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.ts'],
    globals: true,
    env: {
      VITE_SUPABASE_URL: 'http://localhost:54321',
      VITE_SUPABASE_PUBLISHABLE_KEY: 'test-publishable-key',
    },
  },
});
