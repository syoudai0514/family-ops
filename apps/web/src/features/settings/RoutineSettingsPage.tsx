import { useHousehold } from '../../app/HouseholdContext';
import { RoutineSchedule } from './RoutineSchedule';
import { TransportTemplateEditor } from './TransportTemplateEditor';

export function RoutineSettingsPage() {
  const { members } = useHousehold();
  return (
    <>
      <main className="app-shell">
        <h1>いつもの担当</h1>
        <p className="page-lead">
          送り迎えは生活パターンごとに1週間まとめて設定します。今日だけの変更は、その日の詳細から変更します。
        </p>
        <TransportTemplateEditor members={members} />
      </main>
      <RoutineSchedule />
    </>
  );
}
