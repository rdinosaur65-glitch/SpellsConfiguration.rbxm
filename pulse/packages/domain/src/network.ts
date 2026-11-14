/**
 * Did a request fail because the server could not be reached (keep it and retry later), or
 * because the server refused it (drop it)? Browsers word network failures differently:
 * Chrome "Failed to fetch", Firefox "NetworkError when attempting to fetch resource.",
 * Safari — every browser on iPhone — "Load failed". Server refusals carry a code
 * (e.g. "not_friends") and are never treated as offline.
 */
export function isNetworkFailure(error: unknown, online = true): boolean {
  if (!online) return true;
  const err = (error ?? {}) as { message?: unknown; name?: unknown };
  const name = typeof err.name === 'string' ? err.name : '';
  const msg = typeof err.message === 'string' ? err.message : '';
  if (['TypeError', 'AbortError', 'TimeoutError', 'StorageUnknownError'].includes(name)) return true;
  return /^TypeError\b|failed to fetch|fetch failed|networkerror|network (error|request failed|connection was lost)|load failed|timed out|aborted/i.test(msg);
}
