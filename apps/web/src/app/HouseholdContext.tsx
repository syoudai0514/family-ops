import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { supabase } from '../lib/supabaseClient';
import { useAuth } from './AuthContext';
import type { Household, HouseholdMember, Profile } from '../lib/types';

export type HouseholdMemberWithProfile = HouseholdMember & { profile: Profile | null };

// Setup is a strict two-step wizard, gated by two nullable timestamp columns
// on `households` (set by their respective Edge Functions on success):
//   dropoff_pickup_setup_completed_at   -> configure-dropoff-pickup
//   evening_routine_setup_completed_at  -> configure-evening-routines
// Both null/either null means the corresponding step still needs doing;
// both non-null means the household is fully set up.
export type HouseholdPhase =
  | 'loading'
  | 'no-household'
  | 'dropoff-pickup-wizard'
  | 'evening-routines-wizard'
  | 'ready';

interface HouseholdContextValue {
  phase: HouseholdPhase;
  household: Household | null;
  members: HouseholdMemberWithProfile[];
  me: HouseholdMemberWithProfile | null;
  /** The other adult in the household, if one has joined yet. */
  partner: HouseholdMemberWithProfile | null;
  refresh: () => Promise<void>;
}

const HouseholdContext = createContext<HouseholdContextValue | undefined>(undefined);

function phaseForHousehold(household: Household): HouseholdPhase {
  if (!household.dropoff_pickup_setup_completed_at) return 'dropoff-pickup-wizard';
  if (!household.evening_routine_setup_completed_at) return 'evening-routines-wizard';
  return 'ready';
}

export function HouseholdProvider({ children }: { children: ReactNode }) {
  const { user } = useAuth();
  const [phase, setPhase] = useState<HouseholdPhase>('loading');
  const [household, setHousehold] = useState<Household | null>(null);
  const [members, setMembers] = useState<HouseholdMemberWithProfile[]>([]);

  const load = useCallback(async () => {
    if (!user) {
      setPhase('no-household');
      setHousehold(null);
      setMembers([]);
      return;
    }

    setPhase('loading');

    const { data: myMembership, error: myMembershipError } = await supabase
      .from('household_members')
      .select('household_id, user_id, member_role, joined_at')
      .eq('user_id', user.id)
      .maybeSingle();

    if (myMembershipError || !myMembership) {
      setHousehold(null);
      setMembers([]);
      setPhase('no-household');
      return;
    }

    const householdId = myMembership.household_id;

    const [{ data: householdRow }, { data: memberRows }] = await Promise.all([
      supabase
        .from('households')
        .select('id, name, timezone, evening_routine_setup_completed_at, dropoff_pickup_setup_completed_at')
        .eq('id', householdId)
        .maybeSingle(),
      supabase
        .from('household_members')
        .select('household_id, user_id, member_role, joined_at')
        .eq('household_id', householdId),
    ]);

    const memberList = memberRows ?? [];
    const userIds = memberList.map((m) => m.user_id);
    const { data: profileRows } = userIds.length
      ? await supabase.from('profiles').select('user_id, display_name').in('user_id', userIds)
      : { data: [] as Profile[] };

    const profilesByUserId = new Map((profileRows ?? []).map((p) => [p.user_id, p]));
    const membersWithProfiles: HouseholdMemberWithProfile[] = memberList.map((m) => ({
      ...m,
      profile: profilesByUserId.get(m.user_id) ?? null,
    }));

    setHousehold(householdRow ?? null);
    setMembers(membersWithProfiles);
    setPhase(householdRow ? phaseForHousehold(householdRow) : 'no-household');
  }, [user]);

  useEffect(() => {
    load();
  }, [load]);

  const me = useMemo(
    () => members.find((m) => m.user_id === user?.id) ?? null,
    [members, user],
  );
  const partner = useMemo(
    () => members.find((m) => m.user_id !== user?.id) ?? null,
    [members, user],
  );

  const value: HouseholdContextValue = {
    phase,
    household,
    members,
    me,
    partner,
    refresh: load,
  };

  return <HouseholdContext.Provider value={value}>{children}</HouseholdContext.Provider>;
}

export function useHousehold(): HouseholdContextValue {
  const ctx = useContext(HouseholdContext);
  if (!ctx) throw new Error('useHousehold must be used within a HouseholdProvider');
  return ctx;
}
