import { useEffect, useState, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { EMAIL_PENDING } from '../lib/features';
import { formatBytes, nextUsernameChangeAt, storageState, validateUsername } from '@pulse/domain';
import { rpc, supabase } from '../lib/supabase';
import { errorMessage } from '../lib/errors';
import { relativeTime } from '../lib/time';
import { ACCENTS } from '../lib/theme';
import type { Appearance } from '../lib/types';
import { Avatar, Banner, Button, Field, Header, Spinner, Toggle, useToast } from '../components/ui';
import { useAuth } from '../lib/auth';
import { setStepUp } from '../lib/stepup';
import { Captcha, captchaEnabled } from '../components/Captcha';
import { isIos, isStandalone, useInstall } from '../lib/install';
import { disablePush, enablePush, forgetPushOnThisDevice, pushEnabled, pushSupported } from '../lib/push';

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (<><h2 className="section-title">{title}</h2><div className="card">{children}</div></>);
}

function Seg<T extends string>({ value, options, onChange, label }:
  { value: T; options: Array<[T, string]>; onChange: (v: T) => void; label: string }) {
  return (
    <div className="seg" role="group" aria-label={label}>
      {options.map(([v, l]) => <button key={v} aria-pressed={value === v} onClick={() => onChange(v)}>{l}</button>)}
    </div>
  );
}

export function Settings() {
  const { profile, settings, isOwner, updateSettings, refresh, session } = useAuth();
  const [toast, showToast] = useToast();
  if (!profile || !settings) return <div className="center"><Spinner /></div>;

  const save = async (patch: Parameters<typeof updateSettings>[0]) => {
    try { await updateSettings(patch); } catch (e) { showToast(errorMessage(e)); }
  };
  const setAppearance = (patch: Partial<Appearance>) => save({ appearance: { ...settings.appearance, ...patch } });

  return (
    <div className="screen">
      <Header title="Settings" />
      <div className="profile-hero">
        <Avatar name={profile.display_name} size={84} />
        <h2>{profile.display_name}</h2>
        <span className="muted" data-testid="my-username">@{profile.username}</span>
      </div>

      {isOwner && <Link to="/admin" className="btn btn-subtle" style={{ display: 'flex', justifyContent: 'center', margin: '0 0 8px' }}>Owner panel</Link>}
      <ProfileEditor onSaved={async () => { await refresh(); showToast('Profile saved'); }} onError={showToast} />
      <UsernameEditor isOwner={isOwner} onSaved={async () => { await refresh(); showToast('Username changed'); }} />

      <Section title="Appearance">
        <Seg label="Theme" value={settings.appearance.mode} onChange={(mode) => setAppearance({ mode })}
             options={[['dark', 'Dark'], ['light', 'Light'], ['system', 'System']]} />
        <div className="swatches" role="group" aria-label="Accent colour">
          {ACCENTS.map((c) => (
            <button key={c} className="swatch" style={{ background: c }} aria-label={`Accent ${c}`}
                    aria-pressed={settings.appearance.accent.toLowerCase() === c.toLowerCase()} onClick={() => setAppearance({ accent: c })} />
          ))}
        </div>
        <Seg label="Font" value={settings.appearance.font} onChange={(font) => setAppearance({ font })}
             options={[['system', 'Default'], ['rounded', 'Rounded'], ['serif', 'Serif'], ['mono', 'Mono']]} />
        <Seg label="Chat bubbles" value={settings.appearance.bubbles} onChange={(bubbles) => setAppearance({ bubbles })}
             options={[['rounded', 'Rounded bubbles'], ['square', 'Square bubbles']]} />
        <Toggle label="Reduce motion" checked={settings.appearance.reduce_motion} onChange={(v) => setAppearance({ reduce_motion: v })} />
        <p className="muted small" style={{ padding: '0 16px 14px', margin: 0 }}>Synced to every device you sign in on.</p>
      </Section>

      <Section title="Privacy">
        <Toggle label="Ghost Mode" description="Hide your online status and last active time from everyone."
                checked={settings.ghost_mode} onChange={(v) => save({ ghost_mode: v })} />
        <Toggle label="Show when I'm online" checked={settings.show_online && !settings.ghost_mode} disabled={settings.ghost_mode}
                description={settings.ghost_mode ? 'Hidden while Ghost Mode is on' : undefined} onChange={(v) => save({ show_online: v })} />
        <Toggle label="Show last active" checked={settings.show_last_active && !settings.ghost_mode} disabled={settings.ghost_mode}
                description={settings.ghost_mode ? 'Hidden while Ghost Mode is on' : undefined} onChange={(v) => save({ show_last_active: v })} />
        <Toggle label="Show when I'm typing" checked={settings.show_typing} onChange={(v) => save({ show_typing: v })} />
        <Toggle label="Data saver" description="Load media only when you tap it." checked={settings.data_saver} onChange={(v) => save({ data_saver: v })} />
      </Section>

      <NotificationsSection onToast={showToast} />
      <InstallCard />
      <SecuritySection onToast={showToast} email={session?.user.email ?? ''} />
      <BlockedSection onToast={showToast} />
      <SessionsSection onToast={showToast} />
      <StorageSection />

      <Section title="Account">
        <div className="card-pad">
          <Button variant="ghost" onClick={async () => { await supabase.auth.signOut({ scope: 'local' }); void forgetPushOnThisDevice(); }}>Sign out</Button>
        </div>
      </Section>
      <DeleteAccount email={session?.user.email ?? ''} isOwner={isOwner} />
      <p className="muted small" style={{ textAlign: 'center', margin: '24px 0' }}>PULSE · friends-only · runs on free infrastructure · <Link to="/privacy">Privacy and rules</Link></p>
      {toast}
    </div>
  );
}

function ProfileEditor({ onSaved, onError }: { onSaved: () => void; onError: (m: string) => void }) {
  const { profile } = useAuth();
  const [displayName, setDisplayName] = useState(profile?.display_name ?? '');
  const [bio, setBio] = useState(profile?.bio ?? '');
  const [status, setStatus] = useState(profile?.status_text ?? '');
  const [busy, setBusy] = useState(false);
  const dirty = displayName !== profile?.display_name || bio !== (profile?.bio ?? '') || status !== (profile?.status_text ?? '');

  async function save() {
    if (!profile) return;
    setBusy(true);
    const { error } = await supabase.from('profiles').update({
      display_name: displayName.trim(), bio: bio.trim() || null, status_text: status.trim() || null,
    }).eq('id', profile.id);
    setBusy(false);
    if (error) onError(errorMessage(error)); else onSaved();
  }
  return (
    <Section title="Profile">
      <div className="card-pad">
        <Field label="Display name" maxLength={40} value={displayName} onChange={(e) => setDisplayName(e.target.value)} />
        <Field label="Status" maxLength={60} value={status} placeholder="What's up?" onChange={(e) => setStatus(e.target.value)} />
        <label className="field"><span className="field-label">Bio</span>
          <textarea className="textarea" maxLength={160} value={bio} onChange={(e) => setBio(e.target.value)} />
          <span className="field-hint">{bio.length}/160 · visible to friends only</span></label>
        <Button busy={busy} disabled={!dirty || !displayName.trim()} onClick={save}>Save profile</Button>
      </div>
    </Section>
  );
}

function UsernameEditor({ isOwner, onSaved }: { isOwner: boolean; onSaved: () => void }) {
  const { profile } = useAuth();
  const [value, setValue] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (!profile) return null;
  const next = nextUsernameChangeAt(profile.username_changed_at ? new Date(profile.username_changed_at) : null, new Date(), isOwner);
  const v = validateUsername(value);

  async function save() {
    if (!v.ok) return;
    setBusy(true); setError(null);
    try { await rpc('change_username', { p_new: v.value }); setValue(''); onSaved(); }
    catch (e) { setError(errorMessage(e)); }
    finally { setBusy(false); }
  }
  return (
    <Section title="Username">
      <div className="card-pad">
        {next ? <Banner kind="info">You can change your username again {relativeTime(next.toISOString())}.</Banner> : (
          <>
            {error && <Banner>{error}</Banner>}
            <Field label="New username" autoCapitalize="none" spellCheck={false} maxLength={20} value={value}
                   onChange={(e) => setValue(e.target.value.toLowerCase())}
                   error={value && !v.ok ? errorMessage({ message: v.error }) : null}
                   hint="Once every 48 hours. Your old username stays reserved for you for 30 days." />
            <Button busy={busy} disabled={!v.ok || v.value === profile.username} onClick={save}>Change username</Button>
          </>
        )}
      </div>
    </Section>
  );
}

function SecuritySection({ onToast, email }: { onToast: (m: string) => void; email: string }) {
  const [factors, setFactors] = useState<Array<{ id: string; status: string; friendly_name?: string }> | null>(null);
  const [factorsError, setFactorsError] = useState(false);
  const [enroll, setEnroll] = useState<{ id: string; qr: string; secret: string } | null>(null);
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [newPassword, setNewPassword] = useState('');
  const [error, setError] = useState<string | null>(null);

  async function load() {
    const { data, error } = await supabase.auth.mfa.listFactors();
    // Never show "Off" (and offer setup) when the status could not be read.
    if (error || !data) { setFactorsError(true); return; }
    setFactorsError(false);
    setFactors((data.totp ?? []) as typeof factors);
  }
  useEffect(() => { void load(); }, []);

  async function start() {
    setError(null);
    // Remove abandoned unverified factors first so enrollment can be retried.
    const { data: all } = await supabase.auth.mfa.listFactors();
    for (const f of all?.all ?? []) if (f.status === 'unverified') await supabase.auth.mfa.unenroll({ factorId: f.id });
    const { data, error } = await supabase.auth.mfa.enroll({ factorType: 'totp', friendlyName: `PULSE ${new Date().toLocaleDateString()}` });
    if (error) { setError(errorMessage(error)); return; }
    setEnroll({ id: data.id, qr: data.totp.qr_code, secret: data.totp.secret });
  }
  async function verify() {
    if (!enroll) return;
    setBusy(true); setError(null);
    const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId: enroll.id, code: code.trim() });
    setBusy(false);
    if (error) { setError('That code didn’t work. Check your authenticator app and try again.'); return; }
    setEnroll(null); setCode(''); onToast('Two-step verification is on'); await load();
  }
  async function remove(id: string) {
    if (!confirm('Turn off two-step verification?')) return;
    const { error } = await supabase.auth.mfa.unenroll({ factorId: id });
    if (error) setError(errorMessage(error)); else { onToast('Two-step verification is off'); await load(); }
  }
  async function changePassword() {
    setBusy(true); setError(null);
    const { error } = await supabase.auth.updateUser({ password: newPassword });
    setBusy(false);
    if (error) {
      setError((error as { code?: string }).code === 'reauthentication_needed'
        ? 'For your safety, sign out and back in, then change your password.' : errorMessage(error));
      return;
    }
    setNewPassword(''); onToast(EMAIL_PENDING ? 'Password changed.' : 'Password changed. A security alert was emailed to you.');
  }
  const verified = (factors ?? []).filter((f) => f.status === 'verified');

  return (
    <Section title="Security">
      <div className="card-pad">
        {error && <Banner>{error}</Banner>}
        <div className="row"><span className="grow"><strong>Two-step verification</strong><br />
          <span className="muted small">{factorsError ? 'Couldn’t check right now.' : factors === null ? 'Checking…'
            : verified.length ? (EMAIL_PENDING ? 'On — codes from your authenticator app are required to sign in. Owner resets need PULSE email, which isn’t set up yet, so keep a backup of the setup code.'
              : 'On — codes from your authenticator app are required to sign in. Lost your phone? The PULSE owner can reset it after confirming it’s you.') : 'Off'}</span></span></div>
        {factorsError ? <Button variant="subtle" onClick={() => void load()}>Try again</Button> : factors === null ? <Spinner small /> : verified.length > 0
          ? verified.map((f) => <Button key={f.id} variant="danger" onClick={() => remove(f.id)}>Turn off</Button>)
          : enroll ? (
            <div className="stack">
              <p className="small muted" style={{ margin: 0 }}>Scan this with an authenticator app (any free app works), then enter the 6-digit code.
                Tip: scan it on a second device too, or keep the code below somewhere safe — there are no backup codes.</p>
              <img src={enroll.qr} alt="Authenticator QR code" width={180} height={180} style={{ background: '#fff', borderRadius: 12, justifySelf: 'center' }} />
              <code className="small" style={{ wordBreak: 'break-all', textAlign: 'center' }}>{enroll.secret}</code>
              <Field label="6-digit code" inputMode="numeric" autoComplete="one-time-code" maxLength={6} value={code}
                     onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))} />
              <Button busy={busy} disabled={code.length !== 6} onClick={verify}>Verify and turn on</Button>
            </div>
          ) : <Button variant="subtle" onClick={start}>Set up two-step verification</Button>}
        <hr style={{ border: 0, borderTop: '1px solid var(--border)', width: '100%' }} />
        <Field label="New password" type="password" autoComplete="new-password" value={newPassword}
               onChange={(e) => setNewPassword(e.target.value)} hint={EMAIL_PENDING ? `Signed in as ${email}.` : `Signed in as ${email}. You'll get an email alert.`} />
        <Button variant="subtle" busy={busy} disabled={newPassword.length < 8} onClick={changePassword}>Change password</Button>
      </div>
    </Section>
  );
}

interface SessionRow { id: string; created_at: string; user_agent: string | null; current: boolean }
function describeAgent(ua: string | null): string {
  if (!ua) return 'Unknown device';
  const os = /iPhone|iPad/.test(ua) ? 'iOS' : /Android/.test(ua) ? 'Android' : /Mac OS/.test(ua) ? 'macOS' : /Windows/.test(ua) ? 'Windows' : /Linux/.test(ua) ? 'Linux' : 'Device';
  const br = /Edg\//.test(ua) ? 'Edge' : /Chrome\//.test(ua) ? 'Chrome' : /Firefox\//.test(ua) ? 'Firefox' : /Safari\//.test(ua) ? 'Safari' : 'Browser';
  return `${br} on ${os}`;
}

function SessionsSection({ onToast }: { onToast: (m: string) => void }) {
  const [rows, setRows] = useState<SessionRow[] | null>(null);
  const load = () => rpc<SessionRow[]>('my_sessions').then(setRows).catch((e) => { onToast(errorMessage(e)); setRows([]); });
  useEffect(() => { void load(); }, []);  // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <Section title="Where you're signed in">
      {rows === null ? <div className="card-pad"><Spinner small /></div> : (
        <>
          {rows.map((s) => (
            <div key={s.id} className="setting-row" data-testid="session-row">
              <span className="grow"><strong>{describeAgent(s.user_agent)}</strong>{s.current && <span className="muted small"> · this device</span>}<br />
                <span className="muted small">Signed in {relativeTime(s.created_at)}</span></span>
              {!s.current && <Button className="btn btn-ghost btn-sm" onClick={async () => {
                try { await rpc('revoke_session', { p_session: s.id }); onToast('Signed out that device'); void load(); } catch (e) { onToast(errorMessage(e)); }
              }}>Sign out</Button>}
            </div>
          ))}
          {rows.filter((r) => !r.current).length > 0 && (
            <div className="card-pad">
              <Button variant="danger" onClick={async () => {
                try { const n = await rpc<number>('revoke_other_sessions'); onToast(`Signed out ${n} other device${n === 1 ? '' : 's'}`); void load(); }
                catch (e) { onToast(errorMessage(e)); }
              }}>Sign out everywhere else</Button>
            </div>
          )}
          <p className="muted small" style={{ padding: '0 16px 14px', margin: 0 }}>A signed-out device loses access when its current token expires (within an hour).</p>
        </>
      )}
    </Section>
  );
}

function StorageSection() {
  const [usage, setUsage] = useState<{ memories_bytes_used: number; memories_quota_bytes: number; pool_full: boolean } | null>(null);
  useEffect(() => { rpc<Array<typeof usage>>('my_storage_usage').then((r) => setUsage(r[0] ?? null)).catch(() => {}); }, []);
  if (!usage) return null;
  const st = storageState(usage.memories_bytes_used, usage.memories_quota_bytes, usage.pool_full);
  return (
    <Section title="Backup storage">
      <div className="card-pad">
        <div className="row"><span className="grow">{formatBytes(usage.memories_bytes_used)} of {formatBytes(usage.memories_quota_bytes)} used</span><strong>{st.percent}%</strong></div>
        <div style={{ height: 8, borderRadius: 99, background: 'var(--surface-2)', overflow: 'hidden' }}>
          <div style={{ width: `${st.percent}%`, height: '100%', background: st.warning ? 'var(--warning)' : 'var(--accent)' }} />
        </div>
        <span className="muted small">Memories stay on your device. Cloud backup is optional and small, because PULSE runs on free hosting.</span>
      </div>
    </Section>
  );
}

function InstallCard() {
  const { canPrompt, prompt } = useInstall();
  if (isStandalone()) return null;
  return (
    <Section title="Install PULSE">
      <div className="card-pad install-card" data-testid="install-card">
        <span className="small">Add PULSE to your home screen: it opens full-screen like an app and starts faster.</span>
        {canPrompt ? <Button variant="subtle" onClick={() => void prompt()}>Install</Button>
          : isIos() ? (
            <ol className="small">
              <li>Open PULSE in <strong>Safari</strong>.</li>
              <li>Tap the <strong>Share</strong> button (square with an arrow).</li>
              <li>Choose <strong>Add to Home Screen</strong>, then <strong>Add</strong>.</li>
            </ol>
          ) : <span className="small muted">In your browser menu, choose “Install app” or “Add to Home screen”.</span>}
      </div>
    </Section>
  );
}

function BlockedSection({ onToast }: { onToast: (m: string) => void }) {
  const [rows, setRows] = useState<Array<{ user_id: string; username: string; display_name: string }> | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const load = () => rpc<typeof rows>('my_blocked_users').then(setRows).catch(() => setRows([]));
  useEffect(() => { void load(); }, []);
  if (!rows || rows.length === 0) return null;
  return (
    <Section title="Blocked">
      {rows.map((r) => (
        <div key={r.user_id} className="setting-row" data-testid="blocked-row">
          <span className="grow"><strong>{r.display_name}</strong> <span className="muted small">@{r.username}</span></span>
          <Button className="btn btn-ghost btn-sm" busy={busy === r.user_id} onClick={async () => {
            setBusy(r.user_id);
            try { await rpc('unblock_user', { p_target: r.user_id }); onToast(`Unblocked @${r.username}`); await load(); }
            catch (e) { onToast(errorMessage(e)); } finally { setBusy(null); }
          }}>Unblock</Button>
        </div>
      ))}
      <p className="muted small" style={{ padding: '0 16px 14px', margin: 0 }}>Unblocking does not restore the friendship; send a new request if you want to.</p>
    </Section>
  );
}

function DeleteAccount({ email, isOwner }: { email: string; isOwner: boolean }) {
  const [open, setOpen] = useState(false);
  const [step, setStep] = useState<'password' | 'code'>('password');
  const [password, setPassword] = useState('');
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [captcha, setCaptcha] = useState<string | null>(null);
  const [captchaKey, setCaptchaKey] = useState(0);
  useEffect(() => () => setStepUp(false), []);
  if (isOwner) return null;

  async function finish() {
    try {
      await rpc('request_account_deletion');
      await supabase.auth.signOut({ scope: 'local' });
      setStepUp(false);
    } catch (e) { setError(errorMessage(e)); setBusy(false); }
  }
  // Re-authenticate in place: a fresh password sign-in (the server requires one within
  // 10 minutes), then — for accounts with two-step verification — the code, so the
  // session is back at aal2 before the deletion request.
  async function confirmPassword() {
    if (busy) return;
    setBusy(true); setError(null);
    setStepUp(true);
    const { error: authErr } = await supabase.auth.signInWithPassword({ email, password, options: { captchaToken: captcha ?? undefined } });
    setCaptcha(null); setCaptchaKey((k) => k + 1);
    if (authErr) { setStepUp(false); setBusy(false); setError(errorMessage(authErr)); return; }
    const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    if (aal?.nextLevel === 'aal2' && aal.currentLevel !== 'aal2') { setStep('code'); setBusy(false); return; }
    await finish();
  }
  async function confirmCode() {
    if (busy) return;
    setBusy(true); setError(null);
    const { data } = await supabase.auth.mfa.listFactors();
    const factor = data?.totp.find((f) => f.status === 'verified');
    const res = factor ? await supabase.auth.mfa.challengeAndVerify({ factorId: factor.id, code: code.trim() }) : null;
    if (!factor || res?.error) { setBusy(false); setError('That code didn’t work. Try the newest code from your app.'); return; }
    await finish();
  }
  function cancel() {
    setOpen(false); setStep('password'); setPassword(''); setCode(''); setError(null);
    setStepUp(false);
    window.dispatchEvent(new Event('pulse:mfa-required'));   // re-check: the session may now need its code
  }
  return (
    <Section title="Danger zone">
      <div className="card-pad">
        {!open ? <Button variant="danger" onClick={() => setOpen(true)}>Delete my account</Button> : (
          <>
            <Banner>This permanently deletes your account, friends, chats you sent and your uploads. There is no recovery period.</Banner>
            {error && <Banner>{error}</Banner>}
            {step === 'password' ? (
              <>
                <Field label="Enter your password to confirm" type="password" autoComplete="current-password" value={password}
                       onChange={(e) => setPassword(e.target.value)} />
                <Captcha key={captchaKey} onToken={setCaptcha} />
                <Button variant="danger" busy={busy} disabled={!password || (captchaEnabled && !captcha)} onClick={confirmPassword}>Permanently delete account</Button>
              </>
            ) : (
              <>
                <Field label="Code from your authenticator app" inputMode="numeric" autoComplete="one-time-code" maxLength={6}
                       autoFocus value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))} />
                <Button variant="danger" busy={busy} disabled={code.length !== 6} onClick={confirmCode}>Confirm and delete</Button>
              </>
            )}
            <Button variant="ghost" onClick={cancel}>Cancel</Button>
          </>
        )}
      </div>
    </Section>
  );
}

function NotificationsSection({ onToast }: { onToast: (m: string) => void }) {
  const { settings, updateSettings } = useAuth();
  const [on, setOn] = useState<boolean | null>(null);
  const [busy, setBusy] = useState(false);
  const supported = pushSupported();
  useEffect(() => { if (supported) pushEnabled().then(setOn).catch(() => setOn(false)); else setOn(false); }, [supported]);
  if (!settings) return null;
  const prefs = settings.notifications;
  const setPref = async (key: string, value: boolean) => {
    try { await updateSettings({ notifications: { ...prefs, [key]: value } }); } catch (e) { onToast(errorMessage(e)); }
  };
  async function toggle(v: boolean) {
    if (busy) return;
    setBusy(true);
    try {
      if (v) {
        const r = await enablePush();
        if (r === 'denied') onToast('Notifications are blocked for PULSE in your browser or phone settings.');
        else if (r === 'enabled') onToast('Notifications are on for this device');
        setOn(r === 'enabled');
      } else {
        await disablePush(); setOn(false); onToast('Notifications are off for this device');
      }
    } catch (e) { onToast(errorMessage(e)); }
    finally { setBusy(false); }
  }
  return (
    <Section title="Notifications">
      {supported ? (
        <Toggle label="Notifications on this device" checked={Boolean(on)} disabled={busy || on === null}
          description="They say who it is from — never what they wrote." onChange={(v) => void toggle(v)} />
      ) : (
        <p className="muted small" style={{ padding: '12px 16px', margin: 0 }}>
          {isIos() && !isStandalone()
            ? 'On iPhone and iPad, add PULSE to your Home Screen first (Share → Add to Home Screen), then open it from there to turn on notifications.'
            : 'Notifications are not available in this browser.'}
        </p>
      )}
      <Toggle label="New chats" checked={prefs.messages !== false} onChange={(v) => void setPref('messages', v)} />
      <Toggle label="New Snaps" checked={prefs.snaps !== false} onChange={(v) => void setPref('snaps', v)} />
      <Toggle label="Friend requests" checked={prefs.friend_requests !== false} onChange={(v) => void setPref('friend_requests', v)} />
    </Section>
  );
}
