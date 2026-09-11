import assert from 'node:assert/strict';
import test from 'node:test';
import { validatePassEvidenceRecord } from './evidence-records.mjs';

const HEAD = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const capturedAt = '2026-09-09T15:00:00+09:00';

test('jsdom/Vitest component tests cannot be relabeled as F2 browser PASS evidence', () => {
  assert.throws(
    () => validatePassEvidenceRecord({
      scenarioId: 'CF14-NAVIGATION-RETURN',
      evidenceClass: 'browser',
      status: 'PASS',
      exactHead: HEAD,
      capturedAt,
      source: 'artifact://vitest/navigation-return',
      details: {
        entryBoundary: 'PWA route',
        interactionArtifact: 'artifact://vitest/log.txt',
        interactionSteps: ['render component', 'fireEvent click'],
        visibleAssertions: ['text exists'],
        environment: { browser: 'jsdom / Vitest', viewport: '393x852' },
      },
    }, { exactHead: HEAD }),
    /must identify a real browser/,
  );
});

test('responsive desktop emulation cannot be relabeled as physical-iPhone PASS evidence', () => {
  assert.throws(
    () => validatePassEvidenceRecord({
      scenarioId: 'CF14-NAVIGATION-RETURN',
      evidenceClass: 'physical-iphone-manual',
      status: 'PASS',
      exactHead: HEAD,
      capturedAt,
      source: 'artifact://desktop-responsive/navigation-return',
      details: {
        entryBoundary: 'desktop responsive emulation',
        deviceModel: 'Chrome responsive iPhone preset',
        osVersion: 'macOS browser emulation',
        surface: 'safari',
        interactionSteps: ['open responsive mode'],
        screenshotArtifacts: ['artifact://desktop-responsive/screenshot.png'],
        visibleAssertions: ['layout appears narrow'],
      },
    }, { exactHead: HEAD }),
    /must identify a physical iPhone/,
  );
});
