import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { EMAIL_PENDING } from '../lib/features';
import { formatBytes } from '@pulse/domain';
import { rpc } from '../lib/supabase';
import { errorMessage } from '../lib/errors';
import { relativeTime } from '../lib/time';
import type { AccountState } from '../lib/types';
import { Banner, Button, Header, Icon, Spinner, useToast } from '../components/ui';
import { useAuth } from '../lib/auth';
import { ResetMfaSheet } from '../components/ResetMfa';
import { InvitationsCard, RegistrationCard } from '../components/Invitations';

/**
 * Owner panel. Everything here goes through admin_* RPCs that re-check ownership (and
 * 2FA) on the server and write the audit log. There is no way to read chats, Snaps,
 * Memories or locations from here — reports carry only the snapshot the reporter saw.
 */
type Usage = {
  accounts: number; registration_cap: number; registration_mode: 'invite_only' | 'public'; pending_invitations: number; active_7d: number; messages_total: number; open_reports: number;
  storage_pools: Record<string, { used: number; limit: number; percent: number }>;
  egress_today: number; egress_budget_daily: number; database_bytes: number; database_limit: number; pending_deletions: number;
};
interface Report {
  id: string; target_type: 'user' | 'message' | 'story' | 'group'; target_user_id: string | null; reason: string;
  details: string | null; evidence: Record<string, unknown>; status: string; created_at: string;
}
interface UserRow { id: string; username: string; display_name: string; account_state: AccountState; created_at: string; open_reports: number }
interface AuditRow { id: number; action: string; target_user_id: string | null; details: Record<string, unknown>; created_at: string }
interface ErrorRow { id: number; created_at: string; username: string | null; message: string; stack: string | null; path: string | null; user_agent: string | null; app_version: string | null }

function Card({ title, children }: { title: string; children: ReactNode }) {
  return (<><h2 className="section-title">{title}</h2><div className="card card-pad">{children}</div></>);
}
function Meter({ label, used, limit, fmt = formatBytes }: { label: string; used: number; limit: number; fmt?: (n: number) => string }) {
  const pct = limit > 0 ? Math.min(100, Math.round((100 * used) / limit)) : 0;
  return (
    <div className="stack" style={{ gap: 4 }}>
      <div className="row"><span className="grow small">{label}</span><span className="small muted">{fmt(used)} / {fmt(limit)} · {pct}%</span></div>
      <div className="meter"><div style={{ width: `${pct}%`, background: pct >= 90 ? 'var(--danger)' : pct >= 70 ? 'var(--warning)' : 'var(--accent-solid)' }} /></div>
    </div>
  );
}
const askReason = (what: string) => {
  const r = window.prompt(`Reason for ${what} (kept in the audit log):`);
  return r && r.trim() ? r.trim() : null;
};

export function Admin() {
  const { isOwner, session } = useAuth();
  const [resetFor, setResetFor] = useState<{ id: string; username: string } | null>(null);
  const [usage, setUsage] = useState<Usage | null>(null);
  const [reports, setReports] = useState<Report[] | null>(null);
  const [status, setStatus] = useState<'open' | 'actioned' | 'dismissed'>('open');
  const [query, setQuery] = useState('');
  const [users, setUsers] = useState<UserRow[] | null>(null);
  const [audit, setAudit] = useState<AuditRow[]>([]);
  const [errors, setErrors] = useState<ErrorRow[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [toast, showToast] = useToast();

  const loadSeq = useRef(0), searchSeq = useRef(0);    // only the newest answer may update the screen
  const load = useCallback(async () => {
    const n = ++loadSeq.current;
    try {
      const [u, r, a, er] = await Promise.all([
        rpc<Usage>('admin_usage_summary'),
        rpc<Report[]>('admin_list_reports', { p_status: status }),
        rpc<AuditRow[]>('admin_audit_log', { p_limit: 30 }),
        rpc<ErrorRow[]>('admin_client_errors', { p_limit: 30 }),
      ]);
      if (n !== loadSeq.current) return;
      setUsage(u); setReports(r); setAudit(a); setErrors(er); setError(null);
    } catch (e) { if (n === loadSeq.current) { setError(errorMessage(e)); setReports((x) => x ?? []); } }
  }, [status]);
  useEffect(() => { if (isOwner) void load(); }, [isOwner, load]);

  const searchUsers = useCallback(async (q: string) => {
    const n = ++searchSeq.current;
    try { const rows = await rpc<UserRow[]>('admin_search_users', { p_query: q.trim() || null }); if (n === searchSeq.current) setUsers(rows); }
    catch (e) { if (n === searchSeq.current) showToast(errorMessage(e)); }
  }, [showToast]);
  useEffect(() => {
    if (!isOwner) return;
    const t = setTimeout(() => void searchUsers(query), 300);
    return () => clearTimeout(t);
  }, [query, isOwner, searchUsers]);

  async function act(key: string, fn: () => Promise<unknown>, done: string) {
    if (busy) return;
    setBusy(key);
    try { await fn(); showToast(done); await Promise.all([load(), searchUsers(query)]); }
    catch (e) { showToast(errorMessage(e)); }
    finally { setBusy(null); }
  }
  function setState(user: string, state: AccountState, label: string) {
    const reason = askReason(label);
    if (!reason) return;
    void act(`${user}:${state}`, () => rpc('admin_set_account_state', { p_user: user, p_state: state, p_reason: reason }), 'Account updated');
  }

  if (!isOwner) {
    return <div className="screen"><Header title="Owner panel" left={<Link to="/settings" className="icon-btn" aria-label="Back to settings"><Icon name="back" /></Link>} />
      <Banner>Only the owner can open this page.</Banner></div>;
  }

  return (
    <div className="screen">
      <Header title="Owner panel" left={<Link to="/settings" className="icon-btn" aria-label="Back to settings"><Icon name="back" /></Link>} />
      {error && <Banner>{error}</Banner>}
      <p className="muted small">No access to chats, Snaps, Memories or locations exists — by design. Reports show only what the reporter could see.</p>

      <Card title="Free-tier usage">
        {!usage ? <Spinner small /> : (
          <div className="stack" data-testid="usage">
            {usage.registration_mode === 'public'
              ? <Meter label="Accounts (public registration limit)" used={usage.accounts} limit={usage.registration_cap} fmt={(n) => String(n)} />
              : <span className="small">Accounts: <strong>{usage.accounts}</strong> · invite only · {usage.pending_invitations} invitation{usage.pending_invitations === 1 ? '' : 's'} pending</span>}
            <Meter label="Database" used={usage.database_bytes} limit={usage.database_limit} />
            {Object.entries(usage.storage_pools).map(([pool, p]) => <Meter key={pool} label={`Storage · ${pool}`} used={p.used} limit={p.limit} />)}
            <Meter label="Media downloads today" used={usage.egress_today} limit={usage.egress_budget_daily} />
            <span className="small muted">Active this week: {usage.active_7d} · Messages stored: {usage.messages_total} · Media awaiting deletion: {usage.pending_deletions}</span>
          </div>
        )}
      </Card>

      {usage && <InvitationsCard onToast={showToast} onChange={() => void load()} />}
      {usage && <RegistrationCard mode={usage.registration_mode} cap={usage.registration_cap} accounts={usage.accounts}
        onToast={showToast} onChange={() => void load()} />}

      <h2 className="section-title">Reports{usage ? ` · ${usage.open_reports} open` : ''}</h2>
      <div className="chips" role="toolbar" aria-label="Report status">
        {(['open', 'actioned', 'dismissed'] as const).map((s) => (
          <button key={s} className="chip" aria-pressed={status === s} onClick={() => setStatus(s)}>{s[0]!.toUpperCase() + s.slice(1)}</button>
        ))}
      </div>
      {reports === null ? <Spinner small /> : reports.length === 0 ? <p className="muted small">Nothing here.</p> : (
        <div className="list">
          {reports.map((r) => {
            const ev = r.evidence as { username?: string; display_name?: string; bio?: string; body?: string; kind?: string; name?: string };
            return (
              <div key={r.id} className="card card-pad stack" data-testid="report-row">
                <div className="row"><strong className="grow">{r.target_type} · {r.reason.replace('_', ' ')}</strong>
                  <span className="small muted">{relativeTime(r.created_at)}</span></div>
                {ev.username && <span className="small">Account: <strong>@{ev.username}</strong> ({ev.display_name})</span>}
                {ev.name && <span className="small">Group: <strong>{ev.name}</strong></span>}
                {ev.kind && <span className="small">Message ({ev.kind}): “{ev.body ?? '[media]'}”</span>}
                {ev.bio && <span className="small muted">Bio: {ev.bio}</span>}
                {r.details && <span className="small muted">Reporter's note: {r.details}</span>}
                {r.status === 'open' && (
                  <div className="row" style={{ flexWrap: 'wrap', gap: 6 }}>
                    {r.target_user_id && <Button className="btn btn-danger btn-sm" busy={busy === `${r.id}:s`} onClick={() => {
                      const reason = askReason('suspending this account');
                      if (!reason) return;
                      void act(`${r.id}:s`, async () => {
                        await rpc('admin_set_account_state', { p_user: r.target_user_id, p_state: 'suspended', p_reason: `${reason} (report ${r.id})` });
                        await rpc('admin_resolve_report', { p_report: r.id, p_status: 'actioned', p_note: reason });
                      }, 'Account suspended');
                    }}>Suspend account</Button>}
                    <Button className="btn btn-ghost btn-sm" busy={busy === `${r.id}:d`}
                      onClick={() => void act(`${r.id}:d`, () => rpc('admin_resolve_report', { p_report: r.id, p_status: 'dismissed', p_note: null }), 'Report dismissed')}>
                      Dismiss</Button>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      <h2 className="section-title">Accounts</h2>
      {EMAIL_PENDING && <p className="muted small" data-testid="email-pending" style={{ margin: '0 4px 8px' }}>
        Email is pending: 2FA resets (which email you a code) stay off until PULSE email is set up.</p>}
      <div className="search">
        <Icon name="search" size={20} />
        <div className="field"><input type="search" aria-label="Search accounts" placeholder="Search accounts" value={query}
          autoCapitalize="none" spellCheck={false} onChange={(e) => setQuery(e.target.value)} /></div>
      </div>
      {users === null ? <Spinner small /> : (
        <div className="list">
          {users.map((u) => (
            <div key={u.id} className="list-item admin-row" data-testid="admin-user-row">
              <span className="grow">
                <span className="list-title truncate" style={{ display: 'block' }}>{u.display_name} <span className="muted small">@{u.username}</span></span>
                <span className="list-sub">{u.account_state}{u.open_reports ? ` · ${u.open_reports} open report${u.open_reports > 1 ? 's' : ''}` : ''} · joined {relativeTime(u.created_at)}</span>
              </span>
              <Button className="btn btn-ghost btn-sm" disabled={EMAIL_PENDING} title={EMAIL_PENDING ? 'Needs PULSE email (pending)' : undefined}
                      onClick={() => setResetFor({ id: u.id, username: u.username })}>{EMAIL_PENDING ? 'Reset 2FA (needs email)' : 'Reset 2FA'}</Button>
              {u.account_state === 'active' && <>
                <Button className="btn btn-ghost btn-sm" busy={busy === `${u.id}:suspended`} onClick={() => setState(u.id, 'suspended', `suspending @${u.username}`)}>Suspend</Button>
                <Button className="btn btn-danger btn-sm" busy={busy === `${u.id}:banned`} onClick={() => setState(u.id, 'banned', `banning @${u.username}`)}>Ban</Button>
              </>}
              {(u.account_state === 'suspended' || u.account_state === 'banned') && <>
                <Button className="btn btn-subtle btn-sm" busy={busy === `${u.id}:active`} onClick={() => setState(u.id, 'active', `restoring @${u.username}`)}>Restore</Button>
                <Button className="btn btn-danger btn-sm" busy={busy === `${u.id}:delete`} onClick={() => {
                  if (!confirm(`Permanently delete @${u.username}? This cannot be undone.`)) return;
                  const reason = askReason(`deleting @${u.username}`);
                  if (reason) void act(`${u.id}:delete`, () => rpc('admin_delete_account', { p_user: u.id, p_reason: reason }), 'Deletion started');
                }}>Delete</Button>
              </>}
            </div>
          ))}
        </div>
      )}

      <Card title="App errors (last 14 days)">
        {errors.length === 0 ? <span className="muted small">No errors reported.</span> : errors.map((e) => (
          <details key={e.id} className="small" data-testid="error-row" style={{ marginBottom: 6 }}>
            <summary style={{ overflowWrap: 'anywhere' }}><strong>{e.message}</strong> · {relativeTime(e.created_at)}{e.username ? ` · @${e.username}` : ''}</summary>
            <div className="muted" style={{ overflowWrap: 'anywhere' }}>{e.path} · {e.app_version} · {e.user_agent}</div>
            {e.stack && <pre style={{ whiteSpace: 'pre-wrap', fontSize: 11, margin: '4px 0 0' }}>{e.stack}</pre>}
          </details>
        ))}
      </Card>

      <Card title="Audit log (latest 30)">
        {audit.length === 0 ? <span className="muted small">No actions yet.</span> : audit.map((a) => (
          <div key={a.id} className="small" data-testid="audit-row"><strong>{a.action}</strong> · {relativeTime(a.created_at)}
            {typeof a.details?.reason === 'string' ? <span className="muted"> · {a.details.reason as string}</span> : null}</div>
        ))}
      </Card>
      {resetFor && session?.user.email && (
        <ResetMfaSheet email={session.user.email} target={resetFor} onClose={() => setResetFor(null)}
          onDone={(msg) => { setResetFor(null); showToast(msg); void load(); }} />
      )}
      {toast}
    </div>
  );
}
