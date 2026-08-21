import { Component, type ErrorInfo, type ReactNode } from 'react';

interface Props {
  children: ReactNode;
}

interface State {
  error: Error | null;
}

declare const __FAMILY_OPS_BUILD_SHA__: string;

function diagnosticFor(error: Error) {
  return {
    name: error.name || 'Error',
    message: error.message || 'エラーメッセージはありません。',
  };
}

// A top-level boundary is deliberately user-facing: a malformed remote row
// or an unexpected browser/runtime error must never leave the family with a
// blank PWA and no way to recover after saving a setup step.
export class AppErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // Keep the diagnostic in the device console for support without sending
    // household data to a third party.
    console.error('Family Ops render error', error, info);
  }

  private reload = () => {
    window.location.reload();
  };

  render() {
    if (this.state.error) {
      const diagnostic = diagnosticFor(this.state.error);
      return (
        <main className="app-shell centered" role="alert">
          <h1>画面を表示できませんでした</h1>
          <p>保存した内容は残っています。再読み込みしてください。</p>
          <details data-testid="app-error-diagnostic">
            <summary>診断情報</summary>
            <p>build: {__FAMILY_OPS_BUILD_SHA__}</p>
            <p>error: {diagnostic.name}</p>
            <p>message: {diagnostic.message}</p>
          </details>
          <button type="button" onClick={this.reload}>
            再読み込み
          </button>
        </main>
      );
    }

    return this.props.children;
  }
}
