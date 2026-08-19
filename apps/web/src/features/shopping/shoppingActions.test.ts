import { describe, expect, it } from 'vitest';
import { getShoppingItemActions } from './shoppingActions';
import type { PurchaseMethod, ShoppingItemStatus } from '../../lib/types';

const ALL_METHODS: PurchaseMethod[] = ['store', 'online', 'either', 'undecided'];

describe('getShoppingItemActions', () => {
  it('allows assign, order (if online-capable), purchase (if store-capable), and cancel from "wanted"', () => {
    for (const method of ALL_METHODS) {
      const actions = getShoppingItemActions('wanted', method);
      expect(actions.canAssign).toBe(true);
      expect(actions.canUnassign).toBe(false);
      expect(actions.canOrder).toBe(method !== 'store');
      expect(actions.canPurchase).toBe(method !== 'online');
      expect(actions.canArrive).toBe(false);
      expect(actions.canCancel).toBe(true);
    }
  });

  it('allows assign/unassign, order/purchase (method-gated), and cancel from "assigned"', () => {
    for (const method of ALL_METHODS) {
      const actions = getShoppingItemActions('assigned', method);
      expect(actions.canAssign).toBe(true);
      expect(actions.canUnassign).toBe(true);
      expect(actions.canOrder).toBe(method !== 'store');
      expect(actions.canPurchase).toBe(method !== 'online');
      expect(actions.canArrive).toBe(false);
      expect(actions.canCancel).toBe(true);
    }
  });

  it('only allows arrive and cancel from "ordered", regardless of purchase method', () => {
    for (const method of ALL_METHODS) {
      const actions = getShoppingItemActions('ordered', method);
      expect(actions).toEqual({
        canAssign: false,
        canUnassign: false,
        canOrder: false,
        canPurchase: false,
        canArrive: true,
        canCancel: true,
      });
    }
  });

  it.each<ShoppingItemStatus>(['purchased', 'arrived', 'cancelled'])(
    'allows no actions at all from the terminal status "%s"',
    (status) => {
      for (const method of ALL_METHODS) {
        expect(getShoppingItemActions(status, method)).toEqual({
          canAssign: false,
          canUnassign: false,
          canOrder: false,
          canPurchase: false,
          canArrive: false,
          canCancel: false,
        });
      }
    },
  );

  it('never offers order for a store-only item', () => {
    expect(getShoppingItemActions('wanted', 'store').canOrder).toBe(false);
    expect(getShoppingItemActions('assigned', 'store').canOrder).toBe(false);
  });

  it('never offers purchase for an online-only item', () => {
    expect(getShoppingItemActions('wanted', 'online').canPurchase).toBe(false);
    expect(getShoppingItemActions('assigned', 'online').canPurchase).toBe(false);
  });

  it('offers both order and purchase for "either" and "undecided" methods', () => {
    for (const method of ['either', 'undecided'] as PurchaseMethod[]) {
      expect(getShoppingItemActions('wanted', method).canOrder).toBe(true);
      expect(getShoppingItemActions('wanted', method).canPurchase).toBe(true);
    }
  });
});
