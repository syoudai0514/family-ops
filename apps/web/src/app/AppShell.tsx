import { NavLink, Route, Routes } from 'react-router-dom';
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
import { CategorySettings } from '../features/settings/CategorySettings';
import { HouseholdTerminology } from '../features/settings/HouseholdTerminology';
import { QuickAdd } from '../features/tasks/QuickAdd';
import { TestSimulation } from '../features/testSimulation/TestSimulation';

const PRIMARY_NAV_ITEMS = [
  { to: '/today', label: '今日', icon: '⌂' },
  { to: '/week', label: '週', icon: '▦' },
  { to: '/month', label: '月', icon: '□' },
  { to: '/shopping', label: '買い物', icon: '⌑' },
  { to: '/history', label: '履歴', icon: '◷' },
];

function isLineInAppBrowser(): boolean {
  return typeof navigator !== 'undefined' && /\bLine\//i.test(navigator.userAgent);
}

function BottomNavLink({ item }: { item: (typeof PRIMARY_NAV_ITEMS)[number] }) {
  return (
    <NavLink
      to={item.to}
      className={({ isActive }) => (isActive ? 'bottom-nav-link active' : 'bottom-nav-link')}
      onClick={(event) => {
        // LINE's iOS in-app browser occasionally swallows SPA history navigation
        // after a deep link. Fall back to a native page navigation there so the
        // bottom tabs always remain operable.
        if (isLineInAppBrowser()) {
          event.preventDefault();
          window.location.assign(item.to);
          return;
        }
        window.scrollTo(0, 0);
      }}
    >
      <span aria-hidden="true">{item.icon}</span>
      {item.label}
    </NavLink>
  );
}

export function AppShell() {
  return (
    <div className="app-root">
      <header className="app-nav">
        <NavLink className="app-nav-brand" to="/today">
          <span aria-hidden="true">⌂</span> おうちノート
        </NavLink>
        <nav className="desktop-nav" aria-label="主要メニュー">
          {PRIMARY_NAV_ITEMS.map((item) => (
            <NavLink
              key={item.to}
              to={item.to}
              className={({ isActive }) => (isActive ? 'nav-link active' : 'nav-link')}
            >
              {item.label}
            </NavLink>
          ))}
        </nav>
        <NavLink to="/settings" className="header-icon" aria-label="設定">
          ⚙
        </NavLink>
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
        <Route path="/settings/categories" element={<CategorySettings />} />
        <Route path="/settings/terminology" element={<HouseholdTerminology />} />
        <Route path="/settings/test-simulation" element={<TestSimulation />} />
        <Route path="/checkin/:sessionId" element={<CheckinPage />} />
        <Route path="*" element={<Today />} />
      </Routes>
      <nav className="bottom-nav" aria-label="主要メニュー">
        {PRIMARY_NAV_ITEMS.map((item) => (
          <BottomNavLink key={item.to} item={item} />
        ))}
        <QuickAdd className="bottom-nav-add" />
      </nav>
    </div>
  );
}
