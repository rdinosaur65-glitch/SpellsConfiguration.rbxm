import { Link } from 'react-router-dom';
import { Header, Icon } from '../components/ui';

const CONTACT = (import.meta.env.VITE_OWNER_CONTACT as string | undefined) || 'the person who invited you';

/**
 * Plain-language privacy notice and house rules for the friends beta. It describes
 * what the code actually does (see docs/SECURITY_MODEL.md); the owner should review it
 * and fill in their contact before inviting anyone.
 */
export function Privacy() {
  return (
    <div className="screen legal-page">
      <Header title="Privacy and rules" left={<Link to="/" className="icon-btn" aria-label="Back"><Icon name="back" /></Link>} />
      <p className="muted small">PULSE is a small, friends-only beta run by one person on free hosting. Contact: {CONTACT}.</p>

      <h2 className="section-title">What PULSE stores</h2>
      <ul className="small">
        <li>Your email, username, display name, optional bio and status, and settings.</li>
        <li>Your friend list, blocks, requests, and private nicknames you give friends.</li>
        <li>Messages, photos and Snaps you send — until they disappear (see below).</li>
        <li>When you were last active (hidden from friends with Ghost Mode), and which devices are signed in.</li>
      </ul>

      <h2 className="section-title">What disappears, and when</h2>
      <ul className="small">
        <li>Chats set to “disappear after viewing” vanish a few minutes after everyone has seen them; 24-hour and 7-day modes work the same way. Saved messages stay until unsaved.</li>
        <li>Disappeared messages are kept, invisible, for up to an hour so they can still be reported, then deleted.</li>
        <li>Snaps can be viewed once and replayed once, then expire; unopened Snaps expire after 30 days.</li>
        <li>Anyone can take a screenshot or film the screen. “Allow saving” is an in-app permission, not protection.</li>
      </ul>

      <h2 className="section-title">Who can see what</h2>
      <ul className="small">
        <li>Only accepted friends see your profile. Strangers who search see only your username and display name.</li>
        <li>The owner of PULSE <strong>cannot read your chats, Snaps or photos</strong>; the database does not allow it. Reports show the owner only what the reporter could see.</li>
        <li>If you lose your authenticator app, the owner can turn off your two-step verification after confirming it is you. This needs a code sent to the owner's email; it signs you out everywhere, keeps your password, and you get an email about it.</li>
        <li>If you block someone, they lose your chat at once. You keep it, marked “Blocked”, until you tap ×, which removes it from your list only — nothing is deleted, and their copy of the chat is not touched.</li>
        <li>Messages are protected in transit and at rest by the hosting provider, but they are <strong>not end-to-end encrypted</strong>.</li>
        <li>No ads, no trackers, no selling of data. Photos are re-encoded on your device, which removes location data.</li>
        <li>If the app hits an error, it sends the owner a short technical report (the error, the page, your browser) so it can be fixed — never your messages. Reports are deleted after 14 days.</li>
        <li>If you turn on notifications, your browser's push service (from Google, Apple, Mozilla or Microsoft) delivers them. They are encrypted for your device and only say who something is from — never what they wrote.</li>
      </ul>

      <h2 className="section-title">Deleting your account</h2>
      <p className="small">Settings → Delete my account removes your profile, friendships, the messages you sent and your uploads within minutes. Reports about you keep their snapshot. Your username stays unavailable for 30 days so nobody can pretend to be you. Hosting backups expire on the provider's schedule.</p>

      <h2 className="section-title">House rules</h2>
      <ul className="small">
        <li>Be kind. No harassment, hate, threats, sexual content involving minors, or sharing others' private content without consent.</li>
        <li>You must be old enough to use online services where you live (at least 13).</li>
        <li>The owner can suspend or remove accounts that break these rules.</li>
      </ul>
      <p className="muted small">Beta software: things may break or change. Keep copies of anything you care about.</p>
    </div>
  );
}
