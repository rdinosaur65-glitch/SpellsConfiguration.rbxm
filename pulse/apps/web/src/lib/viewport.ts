/**
 * Keeps --app-h equal to the visible height. On iOS the on-screen keyboard shrinks only the
 * *visual* viewport, so a full-height layout would leave the message box hidden behind the
 * keyboard; tracking visualViewport keeps the composer just above it. Android Chrome
 * resizes the layout itself (interactive-widget=resizes-content), where this is a no-op.
 */
export function trackVisualViewport(): void {
  const vv = window.visualViewport;
  if (!vv) return;
  const root = document.documentElement;
  let frame = 0;
  const update = () => {
    cancelAnimationFrame(frame);
    frame = requestAnimationFrame(() => {
      root.style.setProperty('--app-h', `${Math.round(vv.height)}px`);
      // iOS may scroll the page when focusing an input; keep the app pinned to the top.
      if (vv.offsetTop > 0 && window.scrollY !== 0) window.scrollTo(0, 0);
    });
  };
  vv.addEventListener('resize', update);
  vv.addEventListener('scroll', update);
  update();
}
