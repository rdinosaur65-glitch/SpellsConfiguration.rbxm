import { useCallback, useEffect, useRef, useState } from 'react';
import { Avatar, Banner, Button, Icon, Sheet, Toggle, useToast } from '../components/ui';
import { refreshStreaks } from '../lib/streaks';
import { rpc } from '../lib/supabase';
import { errorMessage } from '../lib/errors';
import { compressImage, uploadMedia } from '../lib/media';
import { useChatList } from '../lib/live';

type Facing = 'user' | 'environment';

/**
 * Camera: live preview, front/back switch, torch where the device reports it, still
 * capture, and sending the photo as a Snap to friends and groups (upload → send_snap).
 * Nothing leaves the device until "Send" is pressed.
 */
export function Camera() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  // Bumped by stop(): a getUserMedia call that resolves after the screen was left or
  // hidden must release its camera immediately instead of leaking it.
  const gen = useRef(0);
  const [facing, setFacing] = useState<Facing>('environment');
  const [state, setState] = useState<'idle' | 'starting' | 'live' | 'denied' | 'unsupported' | 'error'>('idle');
  const [shot, setShot] = useState<string | null>(null);
  const [torch, setTorch] = useState<{ supported: boolean; on: boolean }>({ supported: false, on: false });
  const shotCanvas = useRef<HTMLCanvasElement | null>(null);
  const [sending, setSending] = useState(false);
  // Hold the shutter to record a video Snap (tap = photo).
  const [clip, setClip] = useState<{ blob: Blob; url: string; seconds: number } | null>(null);
  const [recording, setRecording] = useState<number | null>(null);      // seconds elapsed
  const rec = useRef<{ r: MediaRecorder; mic: MediaStream | null; started: number; chunks: Blob[]; timer: ReturnType<typeof setInterval> } | null>(null);
  const hold = useRef<ReturnType<typeof setTimeout> | null>(null);
  const held = useRef(false);          // finger still on the shutter
  const clipStarting = useRef(false);  // waiting for the microphone
  const discard = useRef(false);       // drop the clip being recorded (screen hidden)
  const pickRef = useRef<HTMLInputElement>(null);

  // Fallback when the live camera cannot run here (permission blocked, older iOS home-screen
  // apps, desktop without a camera): take the photo with the phone's own camera app.
  async function fromFile(file: File) {
    try {
      const bmp = await createImageBitmap(file);
      const c = document.createElement('canvas');
      c.width = bmp.width; c.height = bmp.height;
      c.getContext('2d')?.drawImage(bmp, 0, 0);
      bmp.close();
      shotCanvas.current = c;
      setShot(c.toDataURL('image/jpeg', 0.9));
    } catch { showToast('That photo could not be opened.'); }
  }
  const [toast, showToast] = useToast();

  const stop = useCallback(() => {
    gen.current++;
    streamRef.current?.getTracks().forEach((t) => t.stop());
    streamRef.current = null;
  }, []);

  const start = useCallback(async (f: Facing) => {
    if (!navigator.mediaDevices?.getUserMedia) { setState('unsupported'); return; }
    stop();
    const mine = gen.current;
    setState('starting');
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: f, width: { ideal: 1920 }, height: { ideal: 1080 } }, audio: false,
      });
      if (mine !== gen.current || document.visibilityState === 'hidden') {
        stream.getTracks().forEach((t) => t.stop());
        return;
      }
      streamRef.current = stream;
      if (videoRef.current) { videoRef.current.srcObject = stream; await videoRef.current.play().catch(() => {}); }
      const track = stream.getVideoTracks()[0];
      const caps = (track?.getCapabilities?.() ?? {}) as MediaTrackCapabilities & { torch?: boolean };
      setTorch({ supported: Boolean(caps.torch), on: false });
      setState('live');
    } catch (e) {
      if (mine !== gen.current) return;
      const name = (e as DOMException).name;
      setState(name === 'NotAllowedError' || name === 'SecurityError' ? 'denied' : 'error');
    }
  }, [stop]);

  // Release the camera whenever the screen is hidden or left (battery + privacy).
  useEffect(() => {
    const onVis = () => {
      if (document.visibilityState !== 'hidden') return;
      held.current = false;
      if (rec.current) { discard.current = true; void stopClip(); }   // never keep sound recorded in the background
      stop(); setState('idle');
    };
    document.addEventListener('visibilitychange', onVis);
    return () => { document.removeEventListener('visibilitychange', onVis); stop(); };
  }, [stop]);

  const MAX_CLIP_S = 15;
  function videoMime(): string | undefined {
    if (typeof MediaRecorder === 'undefined') return undefined;
    // MP4/H.264 first: it plays on every phone (WebM VP9 does not on older iPhones).
    return ['video/mp4;codecs=avc1,mp4a.40.2', 'video/mp4', 'video/webm;codecs=vp8,opus', 'video/webm;codecs=vp9,opus', 'video/webm']
      .find((t) => MediaRecorder.isTypeSupported(t));
  }
  async function startClip() {
    const cam = streamRef.current;
    const mimeType = videoMime();
    if (!cam || !mimeType || rec.current || clipStarting.current) return;
    clipStarting.current = true;
    // Sound if the microphone is allowed; otherwise a silent clip.
    const mic = await navigator.mediaDevices.getUserMedia({ audio: true }).catch(() => null);
    clipStarting.current = false;
    // Released (or the camera closed) while the microphone was opening: record nothing.
    if (!streamRef.current || !held.current) { mic?.getTracks().forEach((t) => t.stop()); return; }
    discard.current = false;
    const stream = new MediaStream([...cam.getVideoTracks(), ...(mic?.getAudioTracks() ?? [])]);
    const r = new MediaRecorder(stream, { mimeType, videoBitsPerSecond: 1_500_000, audioBitsPerSecond: 64_000 });
    const chunks: Blob[] = [];
    r.ondataavailable = (e) => { if (e.data.size > 0) chunks.push(e.data); };
    const started = performance.now();
    const timer = setInterval(() => {
      const s = (performance.now() - started) / 1000;
      setRecording(Math.floor(s));
      if (s >= MAX_CLIP_S) { if (rec.current?.r === r) void stopClip(); else { clearInterval(timer); if (r.state !== 'inactive') r.stop(); } }
    }, 200);
    r.onstop = () => {
      const seconds = Math.min(MAX_CLIP_S, Math.round((performance.now() - started) / 100) / 10);
      clearInterval(timer);
      mic?.getTracks().forEach((t) => t.stop());
      if (discard.current) { discard.current = false; return; }
      const blob = new Blob(chunks, { type: mimeType.split(';')[0] });
      if (seconds < 0.5 || blob.size === 0) { showToast('Hold a little longer to record a video.'); return; }
      setClip({ blob, url: URL.createObjectURL(blob), seconds });
    };
    rec.current = { r, mic, started, chunks, timer };
    r.start(500);
    setRecording(0);
  }
  async function stopClip() {
    const cur = rec.current;
    rec.current = null;
    setRecording(null);
    if (!cur) return;
    clearInterval(cur.timer);
    cur.mic?.getTracks().forEach((t) => t.stop());
    if (cur.r.state !== 'inactive') cur.r.stop();
  }
  function shutterDown() {
    held.current = true;
    if (hold.current) clearTimeout(hold.current);
    hold.current = setTimeout(() => { hold.current = null; void startClip(); }, 350);
  }
  function shutterUp() {
    held.current = false;
    if (hold.current) { clearTimeout(hold.current); hold.current = null; capture(); return; }   // a tap
    void stopClip();
  }
  function shutterCancel() {          // the system took the touch (e.g. a permission prompt)
    held.current = false;
    if (hold.current) { clearTimeout(hold.current); hold.current = null; return; }
    void stopClip();
  }
  function discardClip() {
    if (clip) URL.revokeObjectURL(clip.url);
    setClip(null);
  }
  useEffect(() => () => { void stopClip(); }, []);   // eslint-disable-line react-hooks/exhaustive-deps

  function capture() {
    const v = videoRef.current;
    if (!v || !v.videoWidth) return;
    const c = document.createElement('canvas');
    c.width = v.videoWidth; c.height = v.videoHeight;
    const ctx = c.getContext('2d');
    if (!ctx) return;
    if (facing === 'user') { ctx.translate(c.width, 0); ctx.scale(-1, 1); }
    ctx.drawImage(v, 0, 0);
    shotCanvas.current = c;
    setShot(c.toDataURL('image/jpeg', 0.9));
  }

  async function toggleTorch() {
    const track = streamRef.current?.getVideoTracks()[0];
    if (!track) return;
    const on = !torch.on;
    try { await track.applyConstraints({ advanced: [{ torch: on } as MediaTrackConstraintSet] }); setTorch({ supported: true, on }); } catch { /* unsupported */ }
  }

  return (
    <div className="camera">
      <video ref={videoRef} playsInline muted className={facing === 'user' ? 'mirror' : ''} style={{ display: state === 'live' && !shot && !clip ? 'block' : 'none' }} />
      {shot && <img src={shot} alt="Captured" className="shot" />}
      {clip && <video src={clip.url} className="shot" autoPlay loop playsInline muted data-testid="clip-preview" aria-label="Recorded video" />}
      {recording !== null && <span className="pill rec-pill" data-testid="clip-recording">● {recording}s / {MAX_CLIP_S}s</span>}

      {state !== 'live' && !shot && (
        <div className="camera-msg">
          {state === 'denied' ? <p>Camera access is blocked. Allow it in your browser's site settings, then try again.</p>
            : state === 'unsupported' ? <p>This browser can't use the camera.</p>
            : state === 'error' ? <p>The camera couldn't start. Another app may be using it.</p>
            : <p>Point, shoot, share with friends.</p>}
          {state !== 'unsupported' && <Button busy={state === 'starting'} onClick={() => start(facing)}>Open camera</Button>}
          {(state === 'denied' || state === 'unsupported' || state === 'error') && (
            <Button variant="ghost" onClick={() => pickRef.current?.click()}>Use the phone's camera app</Button>
          )}
          <input ref={pickRef} type="file" accept="image/*" capture="environment" hidden data-testid="camera-file"
                 onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) void fromFile(f); }} />
          <span className="pill">Nothing is recorded until you press the shutter.</span>
        </div>
      )}

      <div className="camera-top">
        {shot ? <button className="cam-btn" aria-label="Discard photo" onClick={() => setShot(null)}><Icon name="close" /></button>
          : clip ? <button className="cam-btn" aria-label="Discard video" onClick={discardClip}><Icon name="close" /></button> : <span />}
        {state === 'live' && !shot && !clip && recording === null && (
          <div className="row">
            {torch.supported && <button className="cam-btn" aria-pressed={torch.on} aria-label="Torch" onClick={toggleTorch}>⚡</button>}
            <button className="cam-btn" aria-label="Switch camera" onClick={() => { const f = facing === 'user' ? 'environment' : 'user'; setFacing(f); void start(f); }}>
              <Icon name="flip" />
            </button>
          </div>
        )}
      </div>

      <div className="camera-bottom">
        {state === 'live' && !shot && !clip && (
          <button className={`shutter${recording !== null ? ' recording' : ''}`} aria-label="Take photo (hold to record a video)"
                  onPointerDown={(e) => { e.preventDefault(); shutterDown(); }} onPointerUp={shutterUp}
                  onPointerCancel={shutterCancel}
                  onPointerLeave={() => { held.current = false; if (recording !== null) void stopClip(); }}
                  onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); capture(); } }}
                  onContextMenu={(e) => e.preventDefault()} />
        )}
        {(shot || clip) && (
          <div className="row" style={{ justifyContent: 'center', gap: 10 }}>
            {shot && <a className="btn btn-ghost" href={shot} download={`pulse-${Date.now()}.jpg`}>Save to device</a>}
            {clip && <a className="btn btn-ghost" href={clip.url} download={`pulse-${Date.now()}.${clip.blob.type.includes('mp4') ? 'mp4' : 'webm'}`}>Save to device</a>}
            <Button onClick={() => setSending(true)}>Send to…</Button>
          </div>
        )}
      </div>
      {sending && (shotCanvas.current || clip) && <SendSnap media={clip ? { kind: 'video', blob: clip.blob, seconds: clip.seconds } : { kind: 'photo', canvas: shotCanvas.current! }}
        onClose={() => setSending(false)}
        onSent={(n) => { setSending(false); setShot(null); shotCanvas.current = null; discardClip(); showToast(`Snap sent to ${n}`); }} />}
      {toast}
    </div>
  );
}

const TIMERS: Array<[number | null, string]> = [[1, '1s'], [3, '3s'], [5, '5s'], [10, '10s'], [null, '∞']];

type SnapMedia = { kind: 'photo'; canvas: HTMLCanvasElement } | { kind: 'video'; blob: Blob; seconds: number };

// One client id per captured photo/clip and recipient set: reopening the sheet after a
// slow or lost response retries the same Snap (the server returns it, no duplicate), while
// changing the recipients makes a new one (nobody is silently left out).
const snapIds = new WeakMap<object, Map<string, string>>();
function snapClientId(media: SnapMedia, recipients: string[]): string {
  const key = media.kind === 'photo' ? media.canvas : media.blob;
  const byRecipients = snapIds.get(key) ?? new Map<string, string>();
  snapIds.set(key, byRecipients);
  const k = [...recipients].sort().join(',');
  if (!byRecipients.has(k)) byRecipients.set(k, crypto.randomUUID());
  return byRecipients.get(k)!;
}

function SendSnap({ media, onClose, onSent }: { media: SnapMedia; onClose: () => void; onSent: (summary: string) => void }) {
  const { items } = useChatList();
  const [friends, setFriends] = useState<Array<{ user_id: string; username: string; display_name: string; nickname: string | null }> | null>(null);
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [groups, setGroups] = useState<Set<string>>(new Set());
  const [seconds, setSeconds] = useState<number | null>(5);
  const [allowSave, setAllowSave] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => { rpc<typeof friends>('list_friends').then(setFriends).catch((e) => setError(errorMessage(e))); }, []);
  const groupChats = (items ?? []).filter((c) => c.kind === 'group');
  const toggle = (set: Set<string>, id: string, on: boolean) => { const n = new Set(set); if (on) n.add(id); else n.delete(id); return n; };

  async function send() {
    if (busy) return;
    setBusy(true); setError(null);
    try {
      const asset = media.kind === 'photo'
        ? await uploadMedia(await compressImage(media.canvas), 'snap')
        : await uploadMedia(media.blob, 'snap', { durationSeconds: media.seconds });
      await rpc('send_snap', {
        p_media_asset: asset, p_recipients: [...picked], p_groups: [...groups],
        p_view_seconds: media.kind === 'photo' ? seconds : null, p_allow_saving: allowSave,
        p_client_id: snapClientId(media, [...[...picked].map((x) => `u:${x}`), ...[...groups].map((x) => `g:${x}`)]),
      });
      const n = picked.size + groups.size;
      void refreshStreaks();                       // the server may have just extended a streak
      onSent(n === 1 ? '1 chat' : `${n} chats`);
    } catch (e) { setError(errorMessage(e)); setBusy(false); }
  }

  return (
    <Sheet label="Send Snap" onClose={() => { if (!busy) onClose(); }} style={{ color: 'var(--text)' }}>
      <h2 style={{ fontSize: 18, margin: '4px 4px 8px' }}>Send Snap</h2>
      {error && <Banner>{error}</Banner>}
      {media.kind === 'photo' ? (<>
        <span className="field-label" style={{ margin: '0 4px' }}>Timer</span>
        <div className="timer-grid" role="group" aria-label="Snap timer">
          {TIMERS.map(([v, label]) => (
            <button key={label} className="chip" aria-pressed={seconds === v} onClick={() => setSeconds(v)}>{label}</button>
          ))}
        </div>
      </>) : <p className="muted small" style={{ margin: '0 4px' }}>Video · {media.seconds.toFixed(1)} s — plays once, with sound.</p>}
      <Toggle label="Let them save it" description="An in-app permission; screenshots can't be prevented."
              checked={allowSave} onChange={setAllowSave} />
      <span className="field-label" style={{ margin: '8px 4px 0' }}>Friends</span>
      {friends === null ? null : friends.length === 0 ? <p className="muted small">Add friends first.</p> : friends.map((f) => (
        <label key={f.user_id} className="list-item">
          <input type="checkbox" checked={picked.has(f.user_id)} onChange={(e) => setPicked(toggle(picked, f.user_id, e.target.checked))}
                 aria-label={`Send to ${f.nickname ?? f.display_name}`} />
          <Avatar name={f.nickname ?? f.display_name} size={34} />
          <span className="grow truncate">{f.nickname ?? f.display_name} <span className="muted small">@{f.username}</span></span>
        </label>
      ))}
      {groupChats.length > 0 && <span className="field-label" style={{ margin: '8px 4px 0' }}>Groups</span>}
      {groupChats.map((g) => (
        <label key={g.conversation_id} className="list-item">
          <input type="checkbox" checked={groups.has(g.conversation_id)}
                 onChange={(e) => setGroups(toggle(groups, g.conversation_id, e.target.checked))} aria-label={`Send to ${g.title ?? 'group'}`} />
          <Avatar name={g.title ?? 'Group'} size={34} />
          <span className="grow truncate">{g.title ?? 'Group'}</span>
        </label>
      ))}
      <Button busy={busy} disabled={picked.size + groups.size === 0} onClick={send}>Send</Button>
      <Button variant="ghost" disabled={busy} onClick={onClose}>Cancel</Button>
    </Sheet>
  );
}
