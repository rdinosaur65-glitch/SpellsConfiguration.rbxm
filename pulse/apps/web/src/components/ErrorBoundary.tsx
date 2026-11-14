import { reportError } from '../lib/errorReport';
import { Component, type ErrorInfo, type ReactNode } from 'react';

/** Last-resort screen so a rendering bug never leaves a blank app. */
export class ErrorBoundary extends Component<{ children: ReactNode }, { error: Error | null }> {
  state = { error: null as Error | null };
  static getDerivedStateFromError(error: Error) { return { error }; }
  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('PULSE crashed', error, info.componentStack);
    reportError(error, 'render');
  }
  render() {
    if (!this.state.error) return this.props.children;
    return (
      <main className="auth">
        <div className="auth-card" style={{ textAlign: 'center' }}>
          <h1 style={{ fontSize: 22 }}>Something went wrong</h1>
          <p className="muted">PULSE hit an unexpected error. Your data is safe on the server.</p>
          <button className="btn btn-primary" onClick={() => window.location.assign(import.meta.env.BASE_URL)}>Reload PULSE</button>
        </div>
      </main>
    );
  }
}
