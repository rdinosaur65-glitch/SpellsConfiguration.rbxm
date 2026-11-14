import { useCallback, useEffect, useRef, useState } from 'react';
import { Button, Icon } from '../components/ui';

type Facing = 'user' | 'environment';

/**
 * Phase 1 camera: live preview, front/back switch, torch where the device reports it,
 * and still capture kept on the device. Sending Snaps (upload + media-url signing)
 * lands with the Phase 3 camera work.
 */
export function Camera() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const [facing, setFacing] = useState<Facing>('environment');
  const [state, setState] = useState<'idle' | 'starting' | 'live' | 'denied' | 'unsupported' | 'error'>('idle');
  const [shot, setShot] = useState<string | null>(null);
  const [torch, setTorch] = useState<{ supported: boolean; on: boolean }>({ supported: false, on: false });

  const stop = useCallback(() => {
    streamRef.current?.getTracks().forEach((t) => t.stop());
    streamRef.current = null;
  }, []);

  const start = useCallback(async (f: Facing) => {
    if (!navigator.mediaDevices?.getUserMedia) { setState('unsupported'); return; }
    stop();
    setState('starting');
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: f, width: { ideal: 1920 }, height: { ideal: 1080 } }, audio: false,
      });
      streamRef.current = stream;
      if (videoRef.current) { videoRef.current.srcObject = stream; await videoRef.current.play().catch(() => {}); }
      const track = stream.getVideoTracks()[0];
      const caps = (track?.getCapabilities?.() ?? {}) as MediaTrackCapabilities & { torch?: boolean };
      setTorch({ supported: Boolean(caps.torch), on: false });
      setState('live');
    } catch (e) {
      const name = (e as DOMException).name;
      setState(name === 'NotAllowedError' || name === 'SecurityError' ? 'denied' : 'error');
    }
  }, [stop]);

  // Release the camera whenever the screen is hidden or left (battery + privacy).
  useEffect(() => {
    const onVis = () => { if (document.visibilityState === 'hidden') { stop(); setState('idle'); } };
    document.addEventListener('visibilitychange', onVis);
    return () => { document.removeEventListener('visibilitychange', onVis); stop(); };
  }, [stop]);

  function capture() {
    const v = videoRef.current;
    if (!v || !v.videoWidth) return;
    const c = document.createElement('canvas');
    c.width = v.videoWidth; c.height = v.videoHeight;
    const ctx = c.getContext('2d');
    if (!ctx) return;
    if (facing === 'user') { ctx.translate(c.width, 0); ctx.scale(-1, 1); }
    ctx.drawImage(v, 0, 0);
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
      <video ref={videoRef} playsInline muted className={facing === 'user' ? 'mirror' : ''} style={{ display: state === 'live' && !shot ? 'block' : 'none' }} />
      {shot && <img src={shot} alt="Captured" className="shot" />}

      {state !== 'live' && !shot && (
        <div className="camera-msg">
          {state === 'denied' ? <p>Camera access is blocked. Allow it in your browser's site settings, then try again.</p>
            : state === 'unsupported' ? <p>This browser can't use the camera.</p>
            : state === 'error' ? <p>The camera couldn't start. Another app may be using it.</p>
            : <p>Point, shoot, share with friends.</p>}
          {state !== 'unsupported' && <Button busy={state === 'starting'} onClick={() => start(facing)}>Open camera</Button>}
          <span className="pill">Nothing is recorded until you press the shutter.</span>
        </div>
      )}

      <div className="camera-top">
        {shot ? <button className="cam-btn" aria-label="Discard photo" onClick={() => setShot(null)}><Icon name="close" /></button> : <span />}
        {state === 'live' && !shot && (
          <div className="row">
            {torch.supported && <button className="cam-btn" aria-pressed={torch.on} aria-label="Torch" onClick={toggleTorch}>⚡</button>}
            <button className="cam-btn" aria-label="Switch camera" onClick={() => { const f = facing === 'user' ? 'environment' : 'user'; setFacing(f); void start(f); }}>
              <Icon name="flip" />
            </button>
          </div>
        )}
      </div>

      <div className="camera-bottom">
        {state === 'live' && !shot && <button className="shutter" aria-label="Take photo" onClick={capture} />}
        {shot && (
          <div className="stack" style={{ justifyItems: 'center' }}>
            <span className="pill">Sending Snaps arrives in the next update. Your photo stays on this device.</span>
            <a className="btn btn-primary" href={shot} download={`pulse-${Date.now()}.jpg`}>Save to device</a>
          </div>
        )}
      </div>
    </div>
  );
}
