import { NavLink, Route, Routes } from 'react-router-dom';
import { supabase } from '../lib/supabaseClient';
import { Today } from '../features/today/Today';
import { Requests } from '../features/requests/Requests';
import { Shopping } from '../features/shopping/Shopping';
import { Handovers } from '../features/handovers/Handovers';
import { Notifications } from '../features/notifications/Notifications';
import { RoutineSchedule } from '../features/settings/RoutineSchedule';
import { CheckinPage } from '../features/checkin/CheckinPage';
import { HistoryPage } from '../features/history/HistoryPage';
import { WeekView } from '../features/planning/WeekView';
import { MonthView } from '../features/planning/MonthView';
import { SettingsHome } from '../features/settings/SettingsHome';

const PRIMARY_NAV_ITEMS = [
  { to: '/today', label: '今日' },
  { to: '/week', label: '週' },
  { to: '/month', label: '月' },
  { to: '/shopping', label: '買い物' },
  { to: '/history', label: '履歴' },
];

export function AppShell() {
  return (
    <div className="app-root">
      <header className="app-nav">
        <NavLink className="app-nav-brand" to="/today">おうちノート</NavLink>
        <nav className="desktop-nav" aria-label="主要メニュー">
          {PRIMARY_NAV_ITEMS.map((item) => (
            <NavLink key={item.to} to={item.to} className={({ isActive }) => (isActive ? 'nav-link active' : 'nav-link')}>
              {item.label}
            </NavLink>
          ))}
          <NavLink to="/requests" className={({ isActive }) => (isActive ? 'nav-link active' : 'nav-link')}>お願い</NavLink>
          <NavLink to="/settings" className={({ isActive }) => (isActive ? 'nav-link active' : 'nav-link')}>設定</NavLink>
        </nav>
        <button type="button" className="sign-out-button" onClick={() => supabase.auth.signOut()}>
          サインアウト
        </button>
      </header>
      <Routes>
        <Route path="/today" element={<Today />} />
        <Route path="/week" element={<WeekView />} />
        <Route path="/month" element={<MonthView />} />
        <Route path="/requests" element={<Requests />} />
        <Route path="/shopping" element={<Shopping />} />
        <Route path="/handovers" element={<Handovers />} />
        <Route path="/history" element={<HistoryPage />} />
        <Route path="/notifications" element={<Notifications />} />
        <Route path="/settings" element={<SettingsHome />} />
        <Route path="/settings/routines" element={<RoutineSchedule />} />
        <Route path="/checkin/:sessionId" element={<CheckinPage />} />
        <Route path="*" element={<Today />} />
      </Routes>
      <nav className="bottom-nav" aria-label="主要メニュー">
        {PRIMARY_NAV_ITEMS.map((item) => (
          <NavLink key={item.to} to={item.to} className={({ isActive }) => (isActive ? 'bottom-nav-link active' : 'bottom-nav-link')}>
            {item.label}
          </NavLink>
        ))}
        <NavLink to="/requests" aria-label="お願いを作成" className="bottom-nav-add">＋</NavLink>
      </nav>
    </div>
  );
}
