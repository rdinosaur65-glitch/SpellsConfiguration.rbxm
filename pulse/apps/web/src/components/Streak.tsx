import { useEffect, useRef } from 'react';
import { ackMilestone, localTime, type Streak } from '../lib/streaks';
import { Sheet } from './ui';

/** 🔥 12 (⌛ when it ends soon). Only shown for a live streak. */
export function StreakBadge({ streak, onClick }: { streak: Streak | undefined; onClick?: () => void }) {
  if (!streak || streak.count < 1) return null;
  const label = `${streak.count}-day streak${streak.at_risk ? ', ending soon' : ''}`;
  const body = <>🔥<span className="streak-count">{streak.count}</span>{streak.at_risk && <span aria-hidden="true"> ⌛</span>}</>;
  return onClick
    ? <button type="button" className="streak" data-testid="streak" aria-label={`${label} — details`} onClick={onClick}>{body}</button>
    : <span className="streak" data-testid="streak" role="img" aria-label={label}>{body}</span>;
}

export function StreakSheet({ streak, name, onClose }: { streak: Streak; name: string; onClose: () => void }) {
  const today = streak.completed_today
    ? `You both sent a Snap today. Next deadline: ${localTime(streak.expires_at)}.`
    : streak.i_sent_today ? `You've sent yours today. ${name} needs to send you a Snap before ${localTime(streak.expires_at)}.`
    : streak.they_sent_today ? `${name} sent one today. Send ${name} a Snap before ${localTime(streak.expires_at)}.`
    : `Send each other a Snap before ${localTime(streak.expires_at)} to keep it.`;
  return (
    <Sheet label="Streak" onClose={onClose}>
      <h2 style={{ fontSize: 18, margin: '4px 4px 8px' }}>🔥 {streak.count}-day streak with {name}</h2>
      <div className="stack" style={{ gap: 8, padding: '0 4px 8px' }} data-testid="streak-sheet">
        <p style={{ margin: 0 }}>{streak.at_risk ? '⌛ ' : ''}{today}</p>
        <p className="small muted" style={{ margin: 0 }}>
          A day counts when you both send each other at least one photo or video Snap directly. Chats, voice
          notes and group Snaps don't count.
        </p>
        <p className="small muted" style={{ margin: 0 }}>
          Streak days end at {localTime(streak.day_ends_at)} your time, the same moment for everyone (server time).
        </p>
        {streak.best > streak.count && <p className="small muted" style={{ margin: 0 }}>Your longest together: {streak.best} days.</p>}
      </div>
    </Sheet>
  );
}

/** A quiet card the first time a milestone is reached; acknowledged at once (never repeated). */
export function MilestoneBanner({ streak, name, onDismiss }: { streak: Streak; name: string; onDismiss: () => void }) {
  const acked = useRef(false);
  useEffect(() => { if (!acked.current) { acked.current = true; void ackMilestone(streak.friend_id); } }, [streak.friend_id]);
  return (
    <div className="milestone" role="status" data-testid="streak-milestone">
      <span className="milestone-burst" aria-hidden="true">🔥</span>
      <span className="grow"><strong>{streak.milestone} days</strong> of Snaps with {name}</span>
      <button className="icon-btn" aria-label="Dismiss" onClick={onDismiss}>✕</button>
    </div>
  );
}
