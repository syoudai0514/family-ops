import { useEffect, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { supabase } from '../../lib/supabaseClient';

/** Whether おうちノートの予定 are currently written to the family's Google Calendar. */
export function useFamilyCalendarWriteTarget(): boolean {
  const { household } = useHousehold();
  const householdId = household?.id ?? null;
  const [active, setActive] = useState(false);
  useEffect(() => {
    if (!householdId) return;
    let cancelled = false;
    void Promise.resolve(
      supabase
        .from('calendar_connections')
        .select('id')
        .eq('household_id', householdId)
        .eq('active', true)
        .eq('is_family_write_target', true)
        .limit(1),
    )
      .then(({ data, error }) => {
        // Unknown means "remind from おうちノート": never assume Google will do it.
        if (!cancelled) setActive(!error && (data?.length ?? 0) > 0);
      })
      .catch(() => {
        if (!cancelled) setActive(false);
      });
    return () => {
      cancelled = true;
    };
  }, [householdId]);
  return active;
}
