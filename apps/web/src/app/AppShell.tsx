import { NavLink, Route, Routes } from 'react-router-dom';
import { supabase } from '../lib/supabaseClient';
import { Today } from '../features/today/Today';
import { Requests } from '../features/requests/Requests';
import { Shopping } from '../features/shopping/Shopping';
import { Handovers, useUnreadHandoverCount } from '../features/handovers/Handovers';
import { Notifications } from '../features/notifications/Notifications';
import { RoutineSchedule } from '../features/settings/RoutineSchedule';
import { CheckinPage } from '../features/checkin/CheckinPage';
import { HistoryPage } from '../features/history/HistoryPage';

const NAV_ITEMS = [
  { to: '/today', label: '今日' },
  { to: '/requests', label: 'お願い' },
  { to: '/shopping', label: '買い物' },
  { to: '/handovers', label: '引き継ぎ' },
  { to: '/history', label: '履歴' },
  { to: '/notifications', label: '通知' },
  { to: '/settings', label: '設定' },
];

export function AppShell() {
  const unreadHandoverCount = useUnreadHandoverCount();

  return (
    <div className="app-root">
      <header className="app-nav">
        <span className="app-nav-brand">Family Ops</span>
        <nav>
          {NAV_ITEMS.map((item) => (
            <NavLink key={item.to} to={item.to} className={({ isActive }) => (isActive ? 'nav-link active' : 'nav-link')}>
              {item.label}
              {item.to === '/handovers' && unreadHandoverCount > 0 && (
                <span className="nav-badge">{unreadHandoverCount}</span>
              )}
            </NavLink>
          ))}
        </nav>
        <button type="button" onClick={() => supabase.auth.signOut()}>
          サインアウト
        </button>
      </header>
      <Routes>
        <Route path="/today" element={<Today />} />
        <Route path="/requests" element={<Requests />} />
        <Route path="/shopping" element={<Shopping />} />
        <Route path="/handovers" element={<Handovers />} />
        <Route path="/history" element={<HistoryPage />} />
        <Route path="/notifications" element={<Notifications />} />
        <Route path="/settings" element={<RoutineSchedule />} />
        <Route path="/checkin/:sessionId" element={<CheckinPage />} />
        <Route path="*" element={<Today />} />
      </Routes>
    </div>
  );
}
