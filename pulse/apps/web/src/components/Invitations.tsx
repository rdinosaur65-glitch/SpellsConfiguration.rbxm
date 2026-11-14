import { useCallback, useEffect, useState } from 'react';
import { rpc } from '../lib/supabase';
import { errorMessage } from '../lib/errors';
import { relativeTime } from '../lib/time';
import { Banner, Button, Spinner } from './ui';

/**
 * Owner panel: invitations and the registration setting. Everything is decided by the
 * database (admin_* functions check ownership and the owner's 2FA; the sign-up gate
 * redeems codes); this screen only shows and asks.
 */
type Status = 'pending' | 'redeemed' | 'expired' | 'revoked';
interface Invitation {
  id: string; code: string | null; note: string | null; status: Status; created_at: string; expires_at: string;
  redeemed_at: string | null; redeemed_username: string | null; awaiting_confirmation: boolean; revoked_at: string | null;
}
const EXPIRY: Array<[number, string]> = [[24, '1 day'], [72, '3 days'], [168, '7 days'], [336, '14 days'], [720, '30 days']];
const LABEL: Record<Status, string> = { pending: 'Pending', redeemed: 'Redeemed', expired: 'Expired', revoked: 'Revoked' };

export const showCode = (c: string) => c.match(/.{1,4}/g)!.join('-');
export const inviteLink = (c: string) => `${window.location.origin}${import.meta.env.BASE_URL}signup?invite=${showCode(c)}`;

async function copy(text: string): Promise<boolean> {
  try { await navigator.clipboard.writeText(text); return true; } catch { return false; }
}

export function InvitationsCard({ onToast, onChange }: { onToast: (m: string) => void; onChange: () => void }) {
  const [list, setList] = useState<Invitation[] | null>(null);
  const [filter, setFilter] = useState<Status | 'all'>('pending');
  const [hours, setHours] = useState(168);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [fresh, setFresh] = useState<{ id: string; code: string } | null>(null);

  const load = useCallback(async () => {
    try { setList(await rpc<Invitation[]>('admin_list_invitations', { p_limit: 500 })); setError(null); }
    catch (e) { setError(errorMessage(e)); setList((l) => l ?? []); }
  }, []);
  useEffect(() => { void load(); }, [load]);

  async function create() {
    setBusy('create'); setError(null);
    try {
      const [row] = await rpc<Array<{ id: string; code: string; expires_at: string }>>('admin_create_invitation',
        { p_valid_hours: hours, p_note: note.trim() || null });
      setFresh({ id: row!.id, code: row!.code }); setNote(''); setFilter('pending');
      await load(); onChange();
    } catch (e) { setError(errorMessage(e)); }
    finally { setBusy(null); }
  }
  async function revoke(i: Invitation) {
    if (!confirm(`Revoke this invitation${i.note ? ` (${i.note})` : ''}? Its link stops working immediately.`)) return;
    setBusy(i.id);
    try {
      await rpc('admin_revoke_invitation', { p_id: i.id });
      if (fresh?.id === i.id) setFresh(null);
      onToast('Invitation revoked'); await load(); onChange();
    } catch (e) { onToast(errorMessage(e)); }
    finally { setBusy(null); }
  }
  async function share(code: string) {
    const url = inviteLink(code);
    if (navigator.share) {
      try { await navigator.share({ title: 'Join me on PULSE', text: 'Here’s your invitation to PULSE:', url }); return; }
      catch (e) { if ((e as Error).name === 'AbortError') return; }
    }
    onToast((await copy(url)) ? 'Link copied' : url);
  }

  const counts = (s: Status) => (list ?? []).filter((i) => i.status === s).length;
  const shown = (list ?? []).filter((i) => filter === 'all' || i.status === filter);

  return (
    <>
      <h2 className="section-title">Invitations</h2>
      <div className="card card-pad stack" data-testid="invitations">
        {error && <Banner>{error}</Banner>}
        <p className="small muted" style={{ margin: 0 }}>Each invitation works for one person, once. Send the link only to the person you mean.</p>
        <div className="row" style={{ gap: 8, flexWrap: 'wrap' }}>
          <label className="field" style={{ flex: '1 1 140px' }}><span className="field-label">Valid for</span>
            <select value={hours} onChange={(e) => setHours(Number(e.target.value))}>
              {EXPIRY.map(([h, l]) => <option key={h} value={h}>{l}</option>)}
            </select></label>
          <label className="field" style={{ flex: '2 1 180px' }}><span className="field-label">Note (optional, only you see it)</span>
            <input value={note} maxLength={60} placeholder="e.g. Sam" onChange={(e) => setNote(e.target.value)} /></label>
        </div>
        <Button busy={busy === 'create'} onClick={() => void create()}>Create invitation</Button>
        {fresh && (
          <div className="card card-pad stack" data-testid="new-invitation" style={{ gap: 6 }}>
            <strong>New invitation</strong>
            <code style={{ fontSize: 20, letterSpacing: 2 }}>{showCode(fresh.code)}</code>
            <span className="small muted" style={{ overflowWrap: 'anywhere' }}>{inviteLink(fresh.code)}</span>
            <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
              <Button className="btn btn-subtle btn-sm" onClick={async () => onToast((await copy(inviteLink(fresh.code))) ? 'Link copied' : 'Copy the link above')}>Copy link</Button>
              <Button className="btn btn-ghost btn-sm" onClick={() => void share(fresh.code)}>Share…</Button>
            </div>
          </div>
        )}
      </div>

      <div className="chips" role="toolbar" aria-label="Invitation status">
        {(['pending', 'redeemed', 'expired', 'revoked'] as const).map((s) => (
          <button key={s} className="chip" aria-pressed={filter === s} onClick={() => setFilter(s)}>{LABEL[s]} · {counts(s)}</button>
        ))}
        <button className="chip" aria-pressed={filter === 'all'} onClick={() => setFilter('all')}>All</button>
      </div>
      {list === null ? <Spinner small /> : shown.length === 0 ? <p className="muted small">No {filter === 'all' ? '' : LABEL[filter].toLowerCase() + ' '}invitations.</p> : (
        <div className="list" data-testid="invitation-list">
          {shown.map((i) => (
            <div key={i.id} className="list-item admin-row" data-testid="invitation-row" data-status={i.status}>
              <span className="grow" style={{ minWidth: 0 }}>
                <span className="list-title" style={{ display: 'block', overflowWrap: 'anywhere' }}>
                  {i.code ? <code>{showCode(i.code)}</code> : <span className="muted">{LABEL[i.status]}</span>}
                  {i.note ? ` · ${i.note}` : ''}
                </span>
                <span className="list-sub">
                  {i.status === 'pending' && `Expires ${relativeTime(i.expires_at)}`}
                  {i.status === 'redeemed' && <>{i.redeemed_username ? `Joined as @${i.redeemed_username}` : 'Used by an account since deleted'} · {relativeTime(i.redeemed_at)}
                    {i.awaiting_confirmation ? ' · waiting for email confirmation' : ''}</>}
                  {i.status === 'expired' && `Expired ${relativeTime(i.expires_at)}`}
                  {i.status === 'revoked' && `Revoked ${relativeTime(i.revoked_at)}`}
                  {` · created ${relativeTime(i.created_at)}`}
                </span>
              </span>
              {i.status === 'pending' && i.code && <>
                <Button className="btn btn-ghost btn-sm" onClick={() => void share(i.code!)}>Share</Button>
                <Button className="btn btn-danger btn-sm" busy={busy === i.id} onClick={() => void revoke(i)}>Revoke</Button>
              </>}
            </div>
          ))}
        </div>
      )}
    </>
  );
}

export function RegistrationCard({ mode, cap, accounts, onToast, onChange }:
  { mode: 'invite_only' | 'public'; cap: number; accounts: number; onToast: (m: string) => void; onChange: () => void }) {
  const [choice, setChoice] = useState(mode);
  const [limit, setLimit] = useState(String(cap));
  const [busy, setBusy] = useState(false);
  useEffect(() => { setChoice(mode); setLimit(String(cap)); }, [mode, cap]);

  async function save() {
    const n = Number(limit);
    if (choice === 'public' && !confirm(`Open PULSE to anyone with the address, up to ${n} accounts? Invitations keep working.`)) return;
    setBusy(true);
    try {
      await rpc('admin_set_registration', { p_mode: choice, p_cap: choice === 'public' ? n : null });
      onToast(choice === 'public' ? 'Public registration is on' : 'PULSE is invite-only'); onChange();
    } catch (e) { onToast(errorMessage(e)); }
    finally { setBusy(false); }
  }
  const changed = choice !== mode || (choice === 'public' && Number(limit) !== cap);
  return (
    <>
      <h2 className="section-title">Registration</h2>
      <div className="card card-pad stack" data-testid="registration">
        <label className="row" style={{ gap: 10, alignItems: 'flex-start' }}>
          <input type="radio" name="reg-mode" checked={choice === 'invite_only'} onChange={() => setChoice('invite_only')} />
          <span><strong>Invite only</strong> (recommended)<br /><span className="small muted">Nobody can join without an invitation from you. No account limit: each invitation is your decision.</span></span>
        </label>
        <label className="row" style={{ gap: 10, alignItems: 'flex-start' }}>
          <input type="radio" name="reg-mode" checked={choice === 'public'} onChange={() => setChoice('public')} />
          <span><strong>Public registration</strong><br /><span className="small muted">Anyone with the address can sign up, up to the account limit (protects the free plan).</span></span>
        </label>
        {choice === 'public' && (
          <label className="field"><span className="field-label">Account limit (now {accounts} accounts)</span>
            <input type="number" inputMode="numeric" min={1} max={10000} value={limit} onChange={(e) => setLimit(e.target.value)} /></label>
        )}
        <Button busy={busy} disabled={!changed || (choice === 'public' && !(Number(limit) >= 1 && Number(limit) <= 10000))} onClick={() => void save()}>Save</Button>
      </div>
    </>
  );
}
