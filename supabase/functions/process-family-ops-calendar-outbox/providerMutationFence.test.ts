import { assertEquals, assertRejects } from 'jsr:@std/assert@1';
import {
  ProviderMutationFencedError,
  withProviderMutationFence,
} from './providerMutationFence.ts';

Deno.test('stale Task mirror authorization prevents the provider mutation callback', async () => {
  let providerMutationCount = 0;
  await assertRejects(
    () => withProviderMutationFence(
      () => Promise.resolve({ authorized: false, reason: 'LEASE_OR_JOB_STALE' }),
      () => {
        providerMutationCount += 1;
        return Promise.resolve(204);
      },
    ),
    ProviderMutationFencedError,
    'LEASE_OR_JOB_STALE',
  );
  assertEquals(providerMutationCount, 0);
});

Deno.test('transferred Family Event ownership prevents the provider mutation callback', async () => {
  let providerMutationCount = 0;
  await assertRejects(
    () => withProviderMutationFence(
      () => Promise.resolve({ authorized: false, reason: 'FAMILY_EVENT_PROVIDER_OWNERSHIP' }),
      () => {
        providerMutationCount += 1;
        return Promise.resolve(204);
      },
    ),
    ProviderMutationFencedError,
    'FAMILY_EVENT_PROVIDER_OWNERSHIP',
  );
  assertEquals(providerMutationCount, 0);
});

Deno.test('each retry is separately authorized before provider mutation', async () => {
  let authorizationCount = 0;
  let providerMutationCount = 0;
  const authorize = () => {
    authorizationCount += 1;
    return Promise.resolve({ authorized: authorizationCount === 1, reason: 'LEASE_OR_JOB_STALE' });
  };
  const mutate = () => {
    providerMutationCount += 1;
    return Promise.resolve(412);
  };

  assertEquals(await withProviderMutationFence(authorize, mutate), 412);
  await assertRejects(
    () => withProviderMutationFence(authorize, mutate),
    ProviderMutationFencedError,
    'LEASE_OR_JOB_STALE',
  );
  assertEquals(authorizationCount, 2);
  assertEquals(providerMutationCount, 1);
});
