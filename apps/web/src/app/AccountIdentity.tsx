import { useState } from 'react';
import { NavLink, useLocation } from 'react-router-dom';
import { supabase } from '../lib/supabaseClient';
import { useAuth } from './AuthContext';
import { useHousehold, type HouseholdMemberWithProfile } from './HouseholdContext';

function memberName(member: HouseholdMemberWithProfile | undefined): string {
  if (!member) return '家族';
  if (member.family_role === 'papa') return 'パパ';
  if (member.family_role === 'mama') return 'ママ';
  return member.profile?.display_name ?? '家族';
}

/**
 * Who this screen belongs to, always visible. Live 2026-09-30: the browser LINE
 * opens was still signed in as the other parent, and nothing on screen said so
 * -- Today simply showed someone else's work.
 */
export function AccountChip() {
  const { user } = useAuth();
  const { members } = useHousehold();
  if (!user) return null;
  const name = memberName(members.find((member) => member.user_id === user.id));
  return (
    <NavLink to="/settings" className="account-chip" aria-label={`${name}としてログイン中（設定）`}>
      {name}
    </NavLink>
  );
}

/**
 * LINE links carry `?for=<member id>` (who the message was sent to). When the
 * browser is signed in as someone else, say so and offer the switch, instead
 * of silently showing the wrong person's day.
 */
export function LinkRecipientBanner() {
  const { user } = useAuth();
  const { members } = useHousehold();
  const location = useLocation();
  const [signingOut, setSigningOut] = useState(false);
  const intended = new URLSearchParams(location.search).get('for');
  if (!user || !intended || intended === user.id) return null;
  const intendedMember = members.find((member) => member.user_id === intended);
  if (!intendedMember) return null;

  async function switchAccount() {
    setSigningOut(true);
    try {
      await supabase.auth.signOut();
    } finally {
      setSigningOut(false);
    }
  }

  const current = memberName(members.find((member) => member.user_id === user.id));
  const target = memberName(intendedMember);
  return (
    <div className="account-mismatch" role="alert">
      <p>
        このLINEのリンクは<strong>{target}</strong>宛てですが、いまは<strong>{current}</strong>でログインしています。
        表示されているのは{current}の予定です。
      </p>
      <button type="button" disabled={signingOut} onClick={() => void switchAccount()}>
        ログアウトして{target}でログイン
      </button>
    </div>
  );
}
