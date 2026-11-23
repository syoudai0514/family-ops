import { useCallback, useState } from 'react';
import { AssignmentReviewPanel, type AssignmentReviewState } from './AssignmentReviewPanel';
import { useHousehold } from '../../app/HouseholdContext';
import { RoutineRoleEditor } from './RoutineRoleEditor';
import { RoutineSchedule } from './RoutineSchedule';
import { TransportTemplateEditor } from './TransportTemplateEditor';

export function RoutineSettingsPage() {
  const { members, household, me } = useHousehold();
  const scope = `${household?.id ?? ''}:${me?.user_id ?? ''}`;
  const [loadedReview, setLoadedReview] = useState<{ scope: string; value: AssignmentReviewState | null } | null>(null);
  const [revision, setRevision] = useState(0);
  const review = loadedReview?.scope === scope ? loadedReview.value : null;
  const onLoaded = useCallback((value: AssignmentReviewState | null) => setLoadedReview({ scope, value }), [scope]);
  const onChanged = useCallback(() => setRevision((value) => value + 1), []);
  return (
    <>
      <main className="app-shell">
        <h1>いつもの担当</h1>
        <p className="page-lead">
          送り迎えは生活パターンごとに1週間まとめて設定します。そのほかの定例は、誰がやるかでまとめた一覧から直せます。今日だけの変更は、その日の詳細から変更します。
        </p>
        <nav className="filter-chips" aria-label="いつもの担当の中身"><a href="#custom-routines">定例</a><a href="#routine-notifications">通知</a></nav>
        <TransportTemplateEditor members={members} />
        {review?.transport_tentative && <p className="empty-hint">送り迎えには相談中の担当があります。相手のLINEには合意後に担当を表示します。</p>}
        {household?.id && me?.user_id && <AssignmentReviewPanel key={scope} onLoaded={onLoaded} onChanged={onChanged} />}
        <RoutineRoleEditor key={revision} tentativeIds={review?.routines.filter((item) => item.tentative).map((item) => item.definition_id)} />
      </main>
      <RoutineSchedule />
    </>
  );
}
