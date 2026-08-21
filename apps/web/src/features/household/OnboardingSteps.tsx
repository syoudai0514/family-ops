import { useRef, useState } from 'react';
import { useHousehold } from '../../app/HouseholdContext';
import { callEdgeFunction, FamilyOpsApiError } from '../../lib/apiClient';
import { EDGE_FUNCTIONS } from '../../lib/edgeFunctions';
import { newOperationId } from '../../lib/id';
import { LineLinkSection } from '../notifications/Notifications';
import { WeekView } from '../planning/WeekView';
import { MorningPreparationEditor, type MorningPreparationEditorHandle } from '../settings/RoutineSchedule';

type OnboardingStep = 'morning_preparation' | 'connections' | 'notifications' | 'week_preview';

function useCompleteStep(step: OnboardingStep) {
  const { refresh } = useHousehold();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const complete = async () => {
    setBusy(true);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.completeOnboardingStep, {
        operation_id: newOperationId(),
        step,
      });
      await refresh();
    } catch (err) {
      setError(err instanceof FamilyOpsApiError ? err.message : '初期設定を保存できませんでした。');
    } finally {
      setBusy(false);
    }
  };
  return { complete, busy, error };
}

export function MorningPreparationStep() {
  const { household, members } = useHousehold();
  const done = useCompleteStep('morning_preparation');
  const editorRef = useRef<MorningPreparationEditorHandle>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const saveAndContinue = async () => {
    setSaveError(null);
    const saved = await editorRef.current?.saveAll();
    if (!saved) {
      setSaveError('変更を保存できなかったため、次へ進みませんでした。');
      return;
    }
    await done.complete();
  };
  return (
    <main className="app-shell onboarding-step">
      <p className="eyebrow">初期設定 5 / 8</p>
      <h1>朝の準備</h1>
      <p>曜日ごとの持ち物を送り担当へ割り当てます。あとから設定で変更できます。</p>
      <MorningPreparationEditor ref={editorRef} householdId={household?.id ?? null} members={members} />
      {(done.error || saveError) && (
        <p role="alert" className="error-text">
          {saveError ?? done.error}
        </p>
      )}
      <button type="button" onClick={() => void saveAndContinue()} disabled={done.busy}>
        {done.busy ? '保存中…' : '保存して次へ'}
      </button>
    </main>
  );
}

export function ConnectionsStep() {
  const done = useCompleteStep('connections');
  const [calendarBusy, setCalendarBusy] = useState(false);
  const [calendarError, setCalendarError] = useState<string | null>(null);
  const connectCalendar = async () => {
    setCalendarBusy(true);
    setCalendarError(null);
    try {
      const result = await callEdgeFunction<{ authorization_url: string }>(
        EDGE_FUNCTIONS.googleCalendarOauthStart,
        { return_to: `${window.location.origin}/today` },
      );
      window.location.assign(result.authorization_url);
    } catch (err) {
      setCalendarError(
        err instanceof FamilyOpsApiError ? err.message : 'Google Calendarを開けませんでした。',
      );
      setCalendarBusy(false);
    }
  };
  return (
    <main className="app-shell onboarding-step">
      <p className="eyebrow">初期設定 6 / 8</p>
      <h1>LINE・カレンダー連携</h1>
      <p>連携は任意です。未接続でも家庭の予定とタスクは利用できます。</p>
      <LineLinkSection />
      <section className="card">
        <h2>Google Calendar</h2>
        <p>予定の重なりをTodayとWeekでお知らせします。</p>
        <button type="button" onClick={() => void connectCalendar()} disabled={calendarBusy}>
          {calendarBusy ? '接続中…' : 'Google Calendarを接続'}
        </button>
        {calendarError && (
          <p role="alert" className="error-text">
            {calendarError}
          </p>
        )}
      </section>
      {done.error && (
        <p role="alert" className="error-text">
          {done.error}
        </p>
      )}
      <button
        type="button"
        className="secondary-button"
        onClick={() => void done.complete()}
        disabled={done.busy}
      >
        {done.busy ? '保存中…' : '接続状況を確認して次へ'}
      </button>
    </main>
  );
}

export function RecommendedNotificationsStep() {
  const done = useCompleteStep('notifications');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const applyRecommended = async () => {
    setBusy(true);
    setError(null);
    try {
      await callEdgeFunction(EDGE_FUNCTIONS.updateNotificationPreferences, {
        operation_id: newOperationId(),
        request_line: true,
        handover_line: true,
        conflict_line: true,
        weekly_digest_line: true,
        daily_assignment_line: true,
        routine_checklist_line: true,
        in_app: true,
      });
      await done.complete();
    } catch (err) {
      setError(
        err instanceof FamilyOpsApiError ? err.message : 'おすすめ通知を保存できませんでした。',
      );
    } finally {
      setBusy(false);
    }
  };
  return (
    <main className="app-shell onboarding-step">
      <p className="eyebrow">初期設定 7 / 8</p>
      <h1>おすすめ通知</h1>
      <section className="card">
        <h2>必要なときだけ知らせる</h2>
        <p>お願い、予定の重複、今日の担当、朝夕チェック、週次まとめを有効にします。</p>
        <button type="button" onClick={() => void applyRecommended()} disabled={busy || done.busy}>
          {busy || done.busy ? '保存中…' : 'おすすめ設定を使う'}
        </button>
      </section>
      {(error || done.error) && (
        <p role="alert" className="error-text">
          {error ?? done.error}
        </p>
      )}
    </main>
  );
}

export function WeekPreviewStep() {
  const done = useCompleteStep('week_preview');
  return (
    <div className="onboarding-preview">
      <div className="app-shell onboarding-preview-heading">
        <p className="eyebrow">初期設定 8 / 8</p>
        <h1>1週間を確認</h1>
        <p>送り・お迎え、家事、朝準備が同じ週に並びます。</p>
        {done.error && (
          <p role="alert" className="error-text">
            {done.error}
          </p>
        )}
        <button type="button" onClick={() => void done.complete()} disabled={done.busy}>
          {done.busy ? '開始中…' : 'この内容で始める'}
        </button>
      </div>
      <WeekView />
    </div>
  );
}
