export function LoadingScreen({ label = '読み込み中…' }: { label?: string }) {
  return (
    <main className="app-shell centered">
      <p role="status">{label}</p>
    </main>
  );
}
