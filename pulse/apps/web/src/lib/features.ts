/**
 * Email is not set up yet (build with VITE_EMAIL_PENDING=true). Screens that rely on email
 * (password reset, owner 2FA reset, security alerts) then say so instead of promising
 * messages that cannot be sent. Nothing is switched off on the server: confirmation is
 * still required for every new account. Remove the flag once SMTP works.
 */
export const EMAIL_PENDING = (import.meta.env.VITE_EMAIL_PENDING as string | undefined) === 'true';
