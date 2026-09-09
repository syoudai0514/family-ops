import assert from 'node:assert/strict';
import test from 'node:test';
import { runClockBoundaryScenario } from './harness.mjs';
import { clockBoundaryFixtures } from './fixtures.mjs';

test('Q88 clock-boundary contract covers weekday, weekend/holiday morning and evening JST edges', async () => {
  const observed = await runClockBoundaryScenario(
    {
      async evaluateClock({ at, dayType, deliveryKind }) {
        const localTime = at.slice(11, 19);
        const boundary = deliveryKind === 'evening'
          ? '20:30:00'
          : dayType === 'weekday'
            ? '06:30:00'
            : '09:00:00';
        return {
          localAt: at,
          deliveryKind,
          shouldDeliver: localTime === boundary,
        };
      },
    },
    clockBoundaryFixtures,
  );

  assert.equal(observed.length, 8);
  assert.deepEqual(
    observed.filter((entry) => entry.observed.shouldDeliver).map((entry) => entry.id),
    ['weekday-morning-at-boundary', 'weekend-morning-at-boundary', 'holiday-morning-at-boundary', 'evening-at-boundary'],
  );
});

test('clock-boundary harness rejects evidence that loses the explicit JST clock', async () => {
  await assert.rejects(
    () => runClockBoundaryScenario(
      {
        async evaluateClock({ deliveryKind }) {
          return { localAt: '2026-09-13T21:30:00Z', deliveryKind, shouldDeliver: true };
        },
      },
      [clockBoundaryFixtures.find((fixture) => fixture.id === 'weekday-morning-at-boundary')],
    ),
    /preserve explicit local clock evidence/,
  );
});
