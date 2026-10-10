import { useCallback, useEffect, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { callEdgeFunction } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';

export interface FamilyChild {
  id: string;
  display_name: string;
  active: boolean;
}
export interface SchoolContext {
  id: string;
  child_id: string;
  school_display_name: string;
  class_display_name: string | null;
  effective_from: string;
  effective_to: string | null;
  recognition_aliases: string[];
  active: boolean;
}
export interface FamilySetup {
  members: Array<{ user_id: string; line_linked: boolean; line_linked_at: string | null }>;
  children: FamilyChild[];
  contexts: SchoolContext[];
}
export function useFamilySetup() {
  const { household } = useHousehold();
  const householdId = household?.id;
  const [data, setData] = useState<FamilySetup | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const refresh = useCallback(async () => {
    if (!householdId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    setError(null);
    try {
      setData(await callEdgeFunction<FamilySetup>(EDGE_FUNCTIONS.familySetup, { action: 'read' }));
    } catch {
      setError('家族の登録・連携状況を取得できませんでした。');
    } finally {
      setLoading(false);
    }
  }, [householdId]);
  useEffect(() => {
    void refresh();
  }, [refresh]);
  return { data, loading, error, refresh };
}
