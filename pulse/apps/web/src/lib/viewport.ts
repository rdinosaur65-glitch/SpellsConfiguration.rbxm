/**
 * Keeps the app inside the *visible* area when an on-screen keyboard is open.
 *
 * Android Chrome resizes the layout itself (interactive-widget=resizes-content), so this
 * changes nothing there. iOS Safari shrinks only the visual viewport and may scroll the
 * page underneath it; the composer would then sit behind the keyboard. We set --app-h to
 * the visible height and, while iOS has scrolled the page (offsetTop > 0), move the app
 * down by the same amount so it exactly covers what the user can see.
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
      const top = Math.max(0, Math.round(vv.offsetTop));
      root.style.setProperty('--vv-top', `${top}px`);
      root.classList.toggle('vv-shifted', top > 0);
    });
  };
  vv.addEventListener('resize', update);
  vv.addEventListener('scroll', update);
  update();
}
