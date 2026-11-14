import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { AuthProvider } from './lib/auth';
import { App } from './App';
import { ErrorBoundary } from './components/ErrorBoundary';
import { applyAppearance } from './lib/theme';
import { trackVisualViewport } from './lib/viewport';
import { captureInstallPrompt } from './lib/install';
import './styles.css';

applyAppearance(undefined);
trackVisualViewport();
captureInstallPrompt();

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ErrorBoundary>
      <BrowserRouter>
        <AuthProvider>
          <App />
        </AuthProvider>
      </BrowserRouter>
    </ErrorBoundary>
  </StrictMode>,
);
