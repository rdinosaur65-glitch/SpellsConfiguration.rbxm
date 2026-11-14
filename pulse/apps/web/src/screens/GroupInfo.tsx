import { useCallback, useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { LIMITS } from '@pulse/domain';
import { rpc, supabase } from '../lib/supabase';
import { errorMessage } from '../lib/errors';
import type { Participant } from '../lib/types';
import { Avatar, Banner, Button, Field, Header, Icon, Sheet, Spinner, useToast } from '../components/ui';
import { ChatImage } from '../components/Media';
import { useAuth } from '../lib/auth';

type Role = Participant['role'];
const ROLE_LABEL: Record<Role, string> = { owner: 'Owner', admin: 'Admin', member: 'Member' };

/**
 * Group info: name and description, members and roles, adding and removing people,
 * handing over ownership, leaving, reporting, and the group's shared photos.
 * Every action is re-checked by the server (owners manage everyone, admins manage
 * ordinary members); the UI only hides what the caller's role cannot do.
 */
export function GroupInfo() {
  const { id: convId = '' } = useParams();
  const nav = useNavigate();
  const { profile, settings } = useAuth();
  const me = profile?.id ?? '';
  const [group, setGroup] = useState<{ name: string; description: string | null } | null>(null);
  const [people, setPeople] = useState<Participant[] | null>(null);
  const [photos, setPhotos] = useState<Array<{ message_id: string; media_asset_id: string }>>([]);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState(false);
  const [adding, setAdding] = useState(false);
  const [menuFor, setMenuFor] = useState<Participant | null>(null);
  const [reporting, setReporting] = useState(false);
  const [busy, setBusy] = useState(false);
  const [toast, showToast] = useToast();

  const load = useCallback(async () => {
    try {
      const [c, ppl, gallery] = await Promise.all([
        supabase.from('conversations').select('kind,name,description').eq('id', convId).maybeSingle(),
        rpc<Participant[]>('conversation_participants', { p_conv: convId }),
        rpc<Array<{ message_id: string; media_asset_id: string | null }>>('conversation_gallery', { p_conv: convId, p_filter: 'photos' }),
      ]);
      if (c.error) throw c.error;
      if (!c.data || c.data.kind !== 'group') { setError('This group is not available.'); setPeople([]); return; }
      setGroup({ name: c.data.name ?? 'Group', description: c.data.description });
      setPeople(ppl);
      setPhotos(gallery.filter((g): g is { message_id: string; media_asset_id: string } => Boolean(g.media_asset_id)).slice(0, 30));
      setError(null);
    } catch (e) { setError(errorMessage(e)); setPeople((p) => p ?? []); }
  }, [convId]);
  useEffect(() => { void load(); }, [load]);

  const myRole: Role | undefined = people?.find((p) => p.user_id === me)?.role;
  const canManage = myRole === 'owner' || myRole === 'admin';
  const others = (people ?? []).filter((p) => p.user_id !== me);

  async function run(fn: () => Promise<unknown>, done: string, after?: () => void) {
    if (busy) return;
    setBusy(true);
    try { await fn(); showToast(done); setMenuFor(null); if (after) after(); else await load(); }
    catch (e) { showToast(errorMessage(e)); }
    finally { setBusy(false); }
  }

  if (people === null) return <div className="screen"><div className="center"><Spinner /></div></div>;

  return (
    <div className="screen">
      <Header title="Group info"
        left={<Link to={`/chats/${convId}`} className="icon-btn" aria-label="Back to chat"><Icon name="back" /></Link>} />
      {error && <Banner>{error}</Banner>}
      {group && (
        <>
          <div className="profile-hero">
            <Avatar name={group.name} size={84} />
            <h2 data-testid="group-name">{group.name}</h2>
            {group.description && <span className="muted">{group.description}</span>}
            {canManage && <Button variant="subtle" onClick={() => setEditing(true)}>Edit name and description</Button>}
          </div>

          <h2 className="section-title">Members · {people.length} of {LIMITS.groupMaxMembers}</h2>
          <div className="list">
            {people.map((p) => {
              const name = p.user_id === me ? 'You' : (p.nickname ?? p.display_name);
              const manageable = p.user_id !== me && (myRole === 'owner' || (myRole === 'admin' && p.role === 'member'));
              return (
                <div key={p.user_id} className="list-item" data-testid="member-row">
                  <Avatar name={p.nickname ?? p.display_name} size={40} />
                  <span className="grow">
                    <span className="list-title truncate" style={{ display: 'block' }}>{name}</span>
                    <span className="list-sub">@{p.username}{p.role !== 'member' ? ` · ${ROLE_LABEL[p.role]}` : ''}</span>
                  </span>
                  {manageable && <button className="icon-btn" aria-label={`Manage ${p.username}`} onClick={() => setMenuFor(p)}>
                    <Icon name="more" size={18} /></button>}
                </div>
              );
            })}
          </div>
          {canManage && people.length < LIMITS.groupMaxMembers && (
            <div className="card-pad"><Button variant="subtle" onClick={() => setAdding(true)}>Add friends</Button></div>
          )}

          {photos.length > 0 && (
            <>
              <h2 className="section-title">Shared photos</h2>
              <div className="photo-grid">
                {photos.map((ph) => <ChatImage key={ph.message_id} assetId={ph.media_asset_id} dataSaver={settings?.data_saver === true} alt="Shared photo" />)}
              </div>
            </>
          )}

          <h2 className="section-title">Leave or report</h2>
          <div className="card-pad stack">
            <Button variant="danger" busy={busy} onClick={() => {
              if (myRole === 'owner' && others.length > 0) { showToast('Make someone else the owner first (tap ⋯ next to them).'); return; }
              if (confirm('Leave this group? You will stop receiving its messages.')) {
                void run(() => rpc('leave_group', { p_conv: convId }), 'You left the group', () => nav('/chats', { replace: true }));
              }
            }}>Leave group</Button>
            <Button variant="ghost" onClick={() => setReporting(true)}>Report group</Button>
          </div>
        </>
      )}

      {editing && group && <EditGroup convId={convId} group={group} onClose={() => setEditing(false)}
        onSaved={() => { setEditing(false); showToast('Group updated'); void load(); }} />}
      {adding && <AddMembers convId={convId} existing={new Set((people ?? []).map((p) => p.user_id))} onClose={() => setAdding(false)}
        onAdded={(n) => { setAdding(false); showToast(n === 1 ? 'Added 1 friend' : `Added ${n} friends`); void load(); }} />}
      {menuFor && (
        <Sheet label={`Manage ${menuFor.username}`} onClose={() => setMenuFor(null)}>
          <p className="muted small" style={{ margin: '4px 4px 8px' }}>{menuFor.nickname ?? menuFor.display_name} · @{menuFor.username} · {ROLE_LABEL[menuFor.role]}</p>
          {myRole === 'owner' && menuFor.role === 'member' && <button className="sheet-item" disabled={busy}
            onClick={() => void run(() => rpc('set_group_role', { p_conv: convId, p_user: menuFor.user_id, p_role: 'admin' }), 'Now an admin')}>Make admin</button>}
          {myRole === 'owner' && menuFor.role === 'admin' && <button className="sheet-item" disabled={busy}
            onClick={() => void run(() => rpc('set_group_role', { p_conv: convId, p_user: menuFor.user_id, p_role: 'member' }), 'Admin rights removed')}>Remove admin rights</button>}
          {myRole === 'owner' && <button className="sheet-item" disabled={busy} onClick={() => {
            if (confirm(`Make @${menuFor.username} the owner? You will become an admin.`)) {
              void run(() => rpc('transfer_group_ownership', { p_conv: convId, p_new_owner: menuFor.user_id }), 'Ownership transferred');
            }
          }}>Make owner</button>}
          <button className="sheet-item danger" disabled={busy} onClick={() => {
            if (confirm(`Remove @${menuFor.username} from the group?`)) {
              void run(() => rpc('remove_group_member', { p_conv: convId, p_user: menuFor.user_id }), 'Removed from the group');
            }
          }}>Remove from group</button>
          <button className="sheet-item" onClick={() => setMenuFor(null)}>Cancel</button>
        </Sheet>
      )}
      {reporting && (
        <Sheet label="Report group" onClose={() => setReporting(false)}>
          <p className="muted small" style={{ margin: '4px 4px 8px' }}>The owner of PULSE sees the group's name and description, never its messages.</p>
          {([['spam', 'Spam'], ['harassment', 'Harassment or bullying'], ['hate', 'Hate speech'], ['other', 'Something else']] as const).map(([v, l]) => (
            <button key={v} className="sheet-item" disabled={busy} onClick={() =>
              void run(() => rpc('report_group', { p_conv: convId, p_reason: v, p_details: null }), 'Report sent. Thank you.', () => setReporting(false))}>{l}</button>
          ))}
          <button className="sheet-item" onClick={() => setReporting(false)}>Cancel</button>
        </Sheet>
      )}
      {toast}
    </div>
  );
}

function EditGroup({ convId, group, onClose, onSaved }:
  { convId: string; group: { name: string; description: string | null }; onClose: () => void; onSaved: () => void }) {
  const [name, setName] = useState(group.name);
  const [description, setDescription] = useState(group.description ?? '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function save() {
    if (busy) return;
    setBusy(true); setError(null);
    try { await rpc('update_group', { p_conv: convId, p_name: name.trim(), p_description: description.trim() || null, p_theme: null }); onSaved(); }
    catch (e) { setError(errorMessage(e)); setBusy(false); }
  }
  return (
    <Sheet label="Edit group" onClose={onClose}>
      {error && <Banner>{error}</Banner>}
      <Field label="Group name" maxLength={50} value={name} onChange={(e) => setName(e.target.value)} autoFocus />
      <Field label="Description (optional)" maxLength={200} value={description} onChange={(e) => setDescription(e.target.value)} />
      <Button busy={busy} disabled={!name.trim()} onClick={save}>Save</Button>
      <Button variant="ghost" onClick={onClose}>Cancel</Button>
    </Sheet>
  );
}

function AddMembers({ convId, existing, onClose, onAdded }:
  { convId: string; existing: Set<string>; onClose: () => void; onAdded: (n: number) => void }) {
  const [friends, setFriends] = useState<Array<{ user_id: string; username: string; display_name: string; nickname: string | null }> | null>(null);
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    rpc<NonNullable<typeof friends>>('list_friends').then((f) => setFriends(f.filter((x) => !existing.has(x.user_id))))
      .catch((e) => setError(errorMessage(e)));
  }, [existing]);
  const room = LIMITS.groupMaxMembers - existing.size;
  async function add() {
    if (busy) return;
    setBusy(true); setError(null);
    try { await rpc('add_group_members', { p_conv: convId, p_members: [...picked] }); onAdded(picked.size); }
    catch (e) { setError(errorMessage(e)); setBusy(false); }
  }
  return (
    <Sheet label="Add friends" onClose={onClose} style={{ maxHeight: '85vh', overflowY: 'auto' }}>
      <h2 style={{ fontSize: 18, margin: '4px 4px 8px' }}>Add friends</h2>
      {error && <Banner>{error}</Banner>}
      {friends === null ? <Spinner /> : friends.length === 0 ? <p className="muted small">All your friends are already here.</p> :
        friends.map((f) => (
          <label key={f.user_id} className="list-item">
            <input type="checkbox" checked={picked.has(f.user_id)} aria-label={`Add ${f.nickname ?? f.display_name}`}
                   disabled={!picked.has(f.user_id) && picked.size >= room}
                   onChange={(e) => { const n = new Set(picked); if (e.target.checked) n.add(f.user_id); else n.delete(f.user_id); setPicked(n); }} />
            <Avatar name={f.nickname ?? f.display_name} size={34} />
            <span className="grow truncate">{f.nickname ?? f.display_name} <span className="muted small">@{f.username}</span></span>
          </label>
        ))}
      <p className="muted small" style={{ margin: '4px' }}>New members see messages sent from now on, not the earlier history.</p>
      <Button busy={busy} disabled={picked.size === 0} onClick={add}>Add {picked.size || ''}</Button>
      <Button variant="ghost" onClick={onClose}>Cancel</Button>
    </Sheet>
  );
}
