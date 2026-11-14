/* Clickjacking guard for hosts that cannot send X-Frame-Options / frame-ancestors
   (GitHub Pages): PULSE never runs inside another site's frame. */
if (window.top !== window.self) {
  document.documentElement.style.display = 'none';
  try { window.top.location.replace(window.self.location.href); } catch (e) { /* blocked: stay hidden */ }
}
