import { useCallback, useEffect, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';

export interface TaskCategoryOption {
  code: string;
  label: string;
  accentToken: string | null;
  isActive?: boolean;
}

const FALLBACK_CATEGORIES: TaskCategoryOption[] = [
  ['medical', '医療'], ['daycare_special', '保育園特別対応'], ['lesson', '習い事'],
  ['school', '学校行事'], ['family', '家族予定'], ['work', '仕事'], ['shopping', '買い物'], ['other', 'その他'],
].map(([code, label]) => ({ code, label, accentToken: null }));

export function useTaskCategories(includeInactive = false) {
  const { household } = useHousehold();
  const [categories, setCategories] = useState<TaskCategoryOption[]>(FALLBACK_CATEGORIES);

  const load = useCallback(async () => {
    if (!household) return;
    let query = supabase
      .from('household_task_categories')
      .select('code, label, accent_token, sort_order, is_active')
      .eq('household_id', household.id)
      .order('sort_order');
    if (!includeInactive) query = query.eq('is_active', true);
    const { data, error } = await query;
    // The fallback intentionally keeps existing households usable until the
    // forward migration has been deployed. It is a read fallback, not a
    // title-based classification path.
    if (!error && data?.length) {
      setCategories(data.map((item) => ({
        code: item.code,
        label: item.label,
        accentToken: item.accent_token,
        isActive: item.is_active !== false,
      })));
    }
  }, [household, includeInactive]);

  useEffect(() => { void load(); }, [load]);
  return { categories, refreshCategories: load };
}
