# Same-device first sign-in

Bundled Pocket ID installs open `/auth/sign-in` before the provider. Returning
users can use their passkey. An invited user with no passkey can open the
invitation on the device they are holding, or request a setup code by email
and enter it in the same sign-in screen. No second device or QR scan is needed.
The original native PKCE challenge and game continuation stay in that session.
External OIDC providers retain their existing flow and policies.

Email setup uses the install's existing transactional sender (`SYSTEM_MAIL_FROM`,
`SYSTEM_SMTP_HOST`, `SYSTEM_SMTP_PORT`, `SYSTEM_SMTP_USERNAME`,
`SYSTEM_SMTP_PASSWORD`, `SYSTEM_SMTP_TLS`). Without a configured sender the page
explains how to obtain an invitation/sign-in link instead of offering a broken
email button. The provider admin connection must be the bundled connection the
installer configures (`POCKET_ID_ADMIN_ENABLED`, `POCKET_ID_ADMIN_URL`,
`POCKET_ID_API_KEY`). Never copy another install's API key or change an owner's
OIDC subject to enable this.

The email request does not create accounts or memberships. It only serves an
active, already invited Burrow account whose matching provider identity has a
verified email, is enabled, and has zero passkeys. Existing passkey accounts
use passkey sign-in or an admin-issued recovery link. Unknown, archived,
disabled, already-enrolled and mismatched identities receive the same page
and no email. The setup code is provider-owned, single-use and expires after
30 minutes. Only its SHA-256 digest is retained in the signed browser session;
`code` is covered by the existing log filter. The code is entered by POST with
CSRF protection and consumed through the existing OIDC state/nonce/PKCE path,
not through a new session-minting endpoint.

Per-node request limits are 20 per IP and three per email per 30-minute bucket;
completion attempts are limited to 30 per IP per bucket. Email keys in these
bounded, expiring counters are hashed. Separate nodes enforce separate limits.
The invitation-link path remains available on installs without email.

Upgrade Core normally to adopt the new entry screen. Updating Core does not
configure an SMTP relay, enroll devices, migrate identities or modify an
external provider. Verify both the web and native app flows on an install
before advertising it as ready for new users.

On an install without SMTP, the first-time screen also accepts a pasted
invitation/sign-in link. It recognises only the primary install's signed
`/auth/link?token=...` or `/auth/handover?code=...`, or the configured provider's
`/lc/...` link. Burrow extracts and verifies that credential without fetching
the supplied URL; the resulting OIDC interaction keeps the original app PKCE
challenge. This avoids switching out to a different browser session to redeem
an invitation. The `setup_link` field is filtered from request logs.
