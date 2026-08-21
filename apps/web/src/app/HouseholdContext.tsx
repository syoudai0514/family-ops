import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react';
import { supabase } from '../lib/supabaseClient';
import { useAuth } from './AuthContext';
import type { Household, HouseholdMember, Profile } from '../lib/types';

export type HouseholdMemberWithProfile = HouseholdMember & { profile: Profile | null };

// First-class onboarding state is persisted on the household. Partner invite
// intentionally precedes every assignment step so a new household never
// silently assigns the partner's work to the creator.
export type HouseholdPhase =
  | 'loading'
  | 'error'
  | 'no-household'
  | 'partner-invite'
  | 'dropoff-pickup-wizard'
  | 'evening-routines-wizard'
  | 'morning-preparation-wizard'
  | 'connections-wizard'
  | 'notifications-wizard'
  | 'week-preview-wizard'
  | 'ready';

interface HouseholdContextValue {
  phase: HouseholdPhase;
  household: Household | null;
  members: HouseholdMemberWithProfile[];
  me: HouseholdMemberWithProfile | null;
  /** The other adult in the household, if one has joined yet. */
  partner: HouseholdMemberWithProfile | null;
  refresh: () => Promise<void>;
  loadError: string | null;
}

const HouseholdContext = createContext<HouseholdContextValue | undefined>(undefined);

export function phaseForHousehold(household: Household, memberCount: number): HouseholdPhase {
  if (memberCount < 2) return 'partner-invite';
  if (!household.dropoff_pickup_setup_completed_at) return 'dropoff-pickup-wizard';
  if (!household.evening_routine_setup_completed_at) return 'evening-routines-wizard';
  if (!household.morning_preparation_setup_completed_at) return 'morning-preparation-wizard';
  if (!household.connections_setup_completed_at) return 'connections-wizard';
  if (!household.notification_preferences_setup_completed_at) return 'notifications-wizard';
  if (!household.onboarding_preview_completed_at) return 'week-preview-wizard';
  return 'ready';
}

export function HouseholdProvider({ children }: { children: ReactNode }) {
  const { user } = useAuth();
  const [phase, setPhase] = useState<HouseholdPhase>('loading');
  const [household, setHousehold] = useState<Household | null>(null);
  const [members, setMembers] = useState<HouseholdMemberWithProfile[]>([]);
  const [loadError, setLoadError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!user) {
      setLoadError(null);
      setPhase('no-household');
      setHousehold(null);
      setMembers([]);
      return;
    }

    setPhase('loading');
    setLoadError(null);

    try {
      const { data: myMembership, error: myMembershipError } = await supabase
        .from('household_members')
        .select('household_id, user_id, member_role, joined_at')
        .eq('user_id', user.id)
        .maybeSingle();

      if (myMembershipError) throw myMembershipError;
      if (!myMembership) {
        setHousehold(null);
        setMembers([]);
        setPhase('no-household');
        return;
      }

      const householdId = myMembership.household_id;
      const [householdResult, membersResult] = await Promise.all([
        supabase
          .from('households')
          .select(
            'id, name, timezone, evening_routine_setup_completed_at, dropoff_pickup_setup_completed_at, morning_preparation_setup_completed_at, connections_setup_completed_at, notification_preferences_setup_completed_at, onboarding_preview_completed_at',
          )
          .eq('id', householdId)
          .maybeSingle(),
        supabase
          .from('household_members')
          .select('household_id, user_id, member_role, joined_at')
          .eq('household_id', householdId),
      ]);
      if (householdResult.error) throw householdResult.error;
      if (membersResult.error) throw membersResult.error;
      if (!householdResult.data) throw new Error('家庭情報が見つかりません。');

      const memberList = membersResult.data ?? [];
      const userIds = memberList.map((m) => m.user_id);
      const profileResult = userIds.length
        ? await supabase.from('profiles').select('user_id, display_name').in('user_id', userIds)
        : { data: [] as Profile[], error: null };
      if (profileResult.error) throw profileResult.error;

      const profilesByUserId = new Map((profileResult.data ?? []).map((p) => [p.user_id, p]));
      const membersWithProfiles: HouseholdMemberWithProfile[] = memberList.map((m) => ({
        ...m,
        profile: profilesByUserId.get(m.user_id) ?? null,
      }));

      setHousehold(householdResult.data);
      setMembers(membersWithProfiles);
      setPhase(phaseForHousehold(householdResult.data, membersWithProfiles.length));
    } catch (err) {
      setLoadError(err instanceof Error ? err.message : '家庭情報を読み込めませんでした。');
      setPhase('error');
    }
  }, [user]);

  useEffect(() => {
    load();
  }, [load]);

  const me = useMemo(() => members.find((m) => m.user_id === user?.id) ?? null, [members, user]);
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
    loadError,
  };

  return <HouseholdContext.Provider value={value}>{children}</HouseholdContext.Provider>;
}

export function useHousehold(): HouseholdContextValue {
  const ctx = useContext(HouseholdContext);
  if (!ctx) throw new Error('useHousehold must be used within a HouseholdProvider');
  return ctx;
}
