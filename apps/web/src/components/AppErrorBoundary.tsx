import { Component, type ErrorInfo, type ReactNode } from 'react';

interface Props {
  children: ReactNode;
}

interface State {
  error: Error | null;
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
      return (
        <main className="app-shell centered" role="alert">
          <h1>画面を表示できませんでした</h1>
          <p>保存した内容は残っています。再読み込みしてください。</p>
          <button type="button" onClick={this.reload}>
            再読み込み
          </button>
        </main>
      );
    }

    return this.props.children;
  }
}
