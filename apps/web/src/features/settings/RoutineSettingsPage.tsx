import { RoutineContentEditor } from './RoutineContentEditor';
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
        <nav className="filter-chips" aria-label="定例の編集"><a href="#routine-content">名前・チェック項目</a><a href="#custom-routines">朝・夜の項目を追加</a><a href="#morning-preparation">朝の準備</a></nav>
        <RoutineContentEditor />
        <TransportTemplateEditor members={members} />
      </main>
      <RoutineSchedule />
    </>
  );
}
