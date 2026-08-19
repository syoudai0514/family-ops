import type { PurchaseMethod, ShoppingItemStatus } from '../../lib/types';

// Pure derivation of which shopping-item mutations are legal to offer for a
// given (status, purchase_method) pair, so the UI never renders a button
// that would come back as INVALID_SHOPPING_TRANSITION.
//
// State machine (as documented by the WP2 backend contract):
//   wanted --assign--> assigned
//   wanted/assigned --order--> ordered      (purchase_method: online|either|undecided)
//   wanted/assigned --purchase--> purchased (purchase_method: store|either|undecided)
//   ordered --arrive--> arrived
//   wanted/assigned/ordered --cancel--> cancelled
//   purchased, arrived, cancelled are terminal: no further actions.
export interface ShoppingItemActions {
  canAssign: boolean; // set/change assignee
  canUnassign: boolean; // clear assignee, return to `wanted`
  canOrder: boolean;
  canPurchase: boolean;
  canArrive: boolean;
  canCancel: boolean;
}

const NO_ACTIONS: ShoppingItemActions = {
  canAssign: false,
  canUnassign: false,
  canOrder: false,
  canPurchase: false,
  canArrive: false,
  canCancel: false,
};

export function getShoppingItemActions(
  status: ShoppingItemStatus,
  purchaseMethod: PurchaseMethod,
): ShoppingItemActions {
  const supportsOnline = purchaseMethod === 'online' || purchaseMethod === 'either' || purchaseMethod === 'undecided';
  const supportsStore = purchaseMethod === 'store' || purchaseMethod === 'either' || purchaseMethod === 'undecided';

  switch (status) {
    case 'wanted':
      return {
        ...NO_ACTIONS,
        canAssign: true,
        canOrder: supportsOnline,
        canPurchase: supportsStore,
        canCancel: true,
      };
    case 'assigned':
      return {
        ...NO_ACTIONS,
        canAssign: true,
        canUnassign: true,
        canOrder: supportsOnline,
        canPurchase: supportsStore,
        canCancel: true,
      };
    case 'ordered':
      return {
        ...NO_ACTIONS,
        canArrive: true,
        canCancel: true,
      };
    case 'purchased':
    case 'arrived':
    case 'cancelled':
      return NO_ACTIONS;
    default:
      return NO_ACTIONS;
  }
}
