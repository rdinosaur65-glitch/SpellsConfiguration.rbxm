/**
 * Keeps the app inside the *visible* area when an on-screen keyboard is open.
 *
 * Android Chrome resizes the layout itself (interactive-widget=resizes-content). iOS Safari
 * shrinks only the visual viewport and may scroll the page underneath it; the composer
 * would then sit behind the keyboard. We set --app-h to the visible height and, while iOS
 * has scrolled the page (offsetTop > 0), move the app down by the same amount so it exactly
 * covers what the user can see. `kb-open` is set while a keyboard takes a large part of the
 * screen (the composer then drops the home-indicator inset).
 *
 * Pinch-zoom also changes the visual viewport. While zoomed (scale ≠ 1) nothing is adjusted,
 * so zooming magnifies the app instead of re-laying it out.
 */
export function trackVisualViewport(): void {
  const vv = window.visualViewport;
  if (!vv) return;
  const root = document.documentElement;
  let frame = 0;
  const update = () => {
    cancelAnimationFrame(frame);
    frame = requestAnimationFrame(() => {
      if (Math.abs(vv.scale - 1) > 0.01) {
        root.style.removeProperty('--app-h');
        root.style.setProperty('--vv-top', '0px');
        root.classList.remove('vv-shifted', 'kb-open');
        return;
      }
      root.style.setProperty('--app-h', `${Math.round(vv.height)}px`);
      const top = Math.max(0, Math.round(vv.offsetTop));
      root.style.setProperty('--vv-top', `${top}px`);
      root.classList.toggle('vv-shifted', top > 0);
      root.classList.toggle('kb-open', window.innerHeight - vv.height > 120 || top > 0);
    });
  };
  vv.addEventListener('resize', update);
  vv.addEventListener('scroll', update);
  update();
}
