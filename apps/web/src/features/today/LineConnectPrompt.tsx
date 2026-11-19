import { useState } from 'react';
import { Link } from 'react-router-dom';
import { useHousehold } from '../../app/HouseholdContext';
import { useFamilySetup } from '../settings/useFamilySetup';

const DISMISS_KEY = 'line-connect-prompt-dismissed';

function readDismissed(): boolean {
  try {
    return window.localStorage.getItem(DISMISS_KEY) === '1';
  } catch {
    return false;
  }
}

/** First thing a person without LINE sees on 今日: one button to the LINE step. */
export function LineConnectPrompt() {
  const { me } = useHousehold();
  const { data } = useFamilySetup();
  const [dismissed, setDismissed] = useState(readDismissed);
  const mine = data?.members?.find((member) => member.user_id === me?.user_id);
  if (dismissed || !mine || mine.line_linked) return null;

  function dismiss() {
    try {
      window.localStorage.setItem(DISMISS_KEY, '1');
    } catch {
      /* the card simply comes back next time */
    }
    setDismissed(true);
  }

  return (
    <section className="card line-connect-prompt" aria-label="LINEとつなぐ">
      <h2>LINEとつなぎましょう</h2>
      <p>つなぐと、毎日の予定や送り迎えがLINEで届きます。1分で終わります。</p>
      <Link className="button-link" to="/notifications">LINEとつなぐ</Link>
      <button type="button" className="text-button" onClick={dismiss}>あとで</button>
    </section>
  );
}
