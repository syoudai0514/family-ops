import { Link } from 'react-router-dom';

export const OUTCOME_CHOICES = [
  {
    title: '項目そのものが間違い',
    description: '作るべきでなかった予定・やることは「キャンセル」。実施結果の「今回は不要」とは分けて履歴に残します。',
    to: '/today',
    action: '対象の「•••」からキャンセル',
  },
  {
    title: '予定は正しいが、今回はやらなかった',
    description: '「できなかった」または「今回は不要」を結果として記録します。項目の存在自体は消しません。',
    to: '/today?entry=checkin',
    action: 'Check-inで結果を選ぶ',
  },
  {
    title: '別の日にやる',
    description: '「再予定」を選び、元の発生を消さずに次の日へつなげます。',
    to: '/today?entry=checkin',
    action: 'Check-inで再予定日を選ぶ',
  },
  {
    title: '結果を付け間違えた',
    description: '履歴から実績を訂正します。登録時刻ではなく元の対象日が実績日です。',
    to: '/history',
    action: '履歴で訂正する',
  },
] as const;

export function OutcomeSemanticsPage() {
  return (
    <main className="app-shell settings-home">
      <div className="today-header">
        <div>
          <p className="eyebrow">削除・中止・結果の違い</p>
          <h1>消す前に、何を直したい？</h1>
        </div>
        <Link to="/settings" className="text-button">設定へ戻る</Link>
      </div>
      <p className="page-lead">「存在が間違い」と「今回はやらなかった」を同じ削除にしません。選んだ意味をcanonical履歴として残します。</p>
      <section className="settings-list" aria-label="削除・結果の選択">
        {OUTCOME_CHOICES.map((choice) => (
          <Link key={choice.title} to={choice.to} className="settings-link">
            <strong>{choice.title}</strong>
            <span>{choice.description}</span>
            <span>{choice.action} →</span>
          </Link>
        ))}
      </section>
      <section className="card">
        <h2>履歴は消さない</h2>
        <p>キャンセル・できなかった・今回は不要・再予定は別の結果です。訂正も上書きで痕跡を消さず、監査情報から追える状態を保ちます。</p>
      </section>
    </main>
  );
}
