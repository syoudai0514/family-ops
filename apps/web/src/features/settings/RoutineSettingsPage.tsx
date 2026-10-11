import { useHousehold } from '../../app/HouseholdContext';
import { RoutineRoleEditor } from './RoutineRoleEditor';
import { RoutineSchedule } from './RoutineSchedule';
import { TransportTemplateEditor } from './TransportTemplateEditor';

export function RoutineSettingsPage() {
  const { members } = useHousehold();
  return (
    <>
      <main className="app-shell">
        <h1>いつもの担当</h1>
        <p className="page-lead">
          送り迎えは生活パターンごとに1週間まとめて設定します。そのほかの定例は、誰がやるかでまとめた一覧から直せます。今日だけの変更は、その日の詳細から変更します。
        </p>
        <nav className="filter-chips" aria-label="いつもの担当の中身"><a href="#custom-routines">定例</a><a href="#routine-notifications">通知</a></nav>
        <TransportTemplateEditor members={members} />
        <RoutineRoleEditor />
      </main>
      <RoutineSchedule />
    </>
  );
}
