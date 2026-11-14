/**
 * Voice recording with MediaRecorder (built into browsers; nothing is uploaded until sent).
 * Chrome/Firefox/Android record Opus in WebM, Safari records AAC in MP4 — both are accepted
 * by the server. Recording stops by itself at MAX_SECONDS.
 */
export const MAX_VOICE_SECONDS = 120;

function pickMime(): string | undefined {
  if (typeof MediaRecorder === 'undefined') return undefined;
  for (const t of ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg;codecs=opus']) {
    if (MediaRecorder.isTypeSupported(t)) return t;
  }
  return undefined;
}

export function voiceSupported(): boolean {
  return Boolean(navigator.mediaDevices?.getUserMedia) && pickMime() !== undefined;
}

export interface Recording { blob: Blob; seconds: number }

export class VoiceRecorder {
  private rec: MediaRecorder | null = null;
  private stream: MediaStream | null = null;
  private chunks: Blob[] = [];
  private started = 0;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private done: ((r: Recording | null) => void) | null = null;

  async start(onAutoStop: () => void): Promise<void> {
    this.stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } });
    const mimeType = pickMime();
    this.rec = new MediaRecorder(this.stream, mimeType ? { mimeType, audioBitsPerSecond: 32000 } : undefined);
    this.chunks = [];
    this.rec.ondataavailable = (e) => { if (e.data.size > 0) this.chunks.push(e.data); };
    this.rec.onstop = () => {
      const seconds = Math.max(0.5, Math.round((performance.now() - this.started) / 100) / 10);
      const blob = new Blob(this.chunks, { type: (this.rec?.mimeType || mimeType || 'audio/webm').split(';')[0] });
      this.release();
      this.done?.(blob.size > 0 ? { blob, seconds: Math.min(seconds, MAX_VOICE_SECONDS) } : null);
      this.done = null;
    };
    this.started = performance.now();
    this.rec.start(1000);
    this.timer = setTimeout(onAutoStop, MAX_VOICE_SECONDS * 1000);
  }

  elapsed(): number { return this.started ? (performance.now() - this.started) / 1000 : 0; }

  /** Stop and return the recording (null if nothing was captured). */
  stop(): Promise<Recording | null> {
    return new Promise((resolve) => {
      if (!this.rec || this.rec.state === 'inactive') { this.release(); resolve(null); return; }
      this.done = resolve;
      this.rec.stop();
    });
  }

  cancel(): void {
    this.done = null;
    try { if (this.rec && this.rec.state !== 'inactive') this.rec.stop(); } catch { /* ignore */ }
    this.release();
  }

  private release(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.stream?.getTracks().forEach((t) => t.stop());
    this.stream = null;
  }
}
