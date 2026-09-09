import assert from 'node:assert/strict';

export function createControlledGoogleProvider(routes) {
  const calls = [];
  return {
    calls,
    async request(input) {
      calls.push(structuredClone(input));
      const route = routes.find((candidate) => candidate.operation === input.operation);
      assert.ok(route, `no controlled Google provider route for ${input.operation}`);
      return structuredClone({
        entryBoundary: 'google-calendar-provider',
        provider: 'google-calendar',
        httpStatus: route.httpStatus ?? 200,
        externalEventId: route.externalEventId,
        etag: route.etag,
        payload: route.payload,
      });
    },
  };
}

export async function runControlledGoogleProviderScenario({ provider, consumer, fixture }) {
  assert.equal(typeof provider?.request, 'function', 'controlled Google provider.request required');
  assert.equal(typeof consumer?.applyProviderResponse, 'function', 'Google consumer.applyProviderResponse required');
  const providerResponse = await provider.request({
    operation: fixture.operation,
    externalEventId: fixture.externalEventId,
  });
  assert.equal(providerResponse.entryBoundary, 'google-calendar-provider');
  assert.equal(providerResponse.provider, 'google-calendar');
  assert.ok(Number.isInteger(providerResponse.httpStatus), `${fixture.id}: provider HTTP status required`);
  assert.equal(providerResponse.externalEventId, fixture.externalEventId, `${fixture.id}: external event identity must be preserved`);
  assert.ok(providerResponse.etag, `${fixture.id}: provider etag required`);

  const result = await consumer.applyProviderResponse({ providerResponse, fixture });
  assert.ok(result.canonicalReadback, `${fixture.id}: canonical readback required`);
  assert.ok(result.userVisibleResult, `${fixture.id}: user-visible result required`);

  if (fixture.expectedCurrentValuePreserved !== undefined) {
    assert.equal(result.currentValuePreserved, fixture.expectedCurrentValuePreserved, `${fixture.id}: protected current-value preservation mismatch`);
  }
  if (fixture.expectedCandidateStartsAt) {
    assert.equal(result.candidate?.startsAt, fixture.expectedCandidateStartsAt, `${fixture.id}: provider change candidate mismatch`);
  }
  if (fixture.expectedChoices) {
    assert.deepEqual(result.choices, fixture.expectedChoices, `${fixture.id}: user-visible provider resolution choices mismatch`);
  }
  return { providerResponse, result };
}
