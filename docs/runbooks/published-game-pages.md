# Published game pages

A public `/games/:slug` page shows a game before sign-in. Burrow OIDC returns
players to the same page; `/games/:slug/releases/:version/download` requires
an active identity and authorizes only the explicitly published artifact.
The chat attachment's original permissions are unchanged.

## Operator publication

Set `GAME_PUBLICATIONS_JSON` on the serving install to a JSON array of manifests.
Absent configuration means no published games. Keep install-specific manifests in the private ops repository. Example shape:

```json
[{
  "slug": "my-game",
  "published": true,
  "org_id": "<game-org-uuid>",
  "title": "My Game",
  "summary": "A little chaos with friends.",
  "image_path": "/images/my-game.png",
  "image_alt": "Gameplay screenshot",
  "multiplayer_note": "Describe the verified launch and admission instructions here.",
  "current_version": "v1",
  "releases": [{
    "version": "v1",
    "attachment_id": "<approved-release-attachment-uuid>",
    "sha256": "<64-lowercase-hex-sha256-of-zip>",
    "byte_size": 89458340
  }]
}]
```

Publishing an existing attachment explicitly permits ANY signed-in, non-archived
identity to download that artifact. This is not a chat-space membership grant.
A portable ZIP is not an installer. Confirm
that it contains no private configs and that the attachment is ready with the
same digest and size. Never put a room code, OIDC credential, user config or
server secret in a manifest. The public page's version and checksum refer to
the ZIP, not its embedded PCK. Retain older version entries when changing the
current pointer; do not repoint a version to different bytes.

## Community identity

The game header and embedded text conversation use only the explicit
`preferences.player_display_name` (trimmed, at most 40 characters), or a stable
opaque `pilot-…` handle. Account names, email and account avatars are never
fallbacks. Old author snapshots are ignored by this renderer, including messages
posted through other Burrow clients. A name-selection UI belongs to the broader
persona work; this slice defaults to the generated handle.

The embedded view uses Burrow's existing message store, permissions and PubSub.
It is a text-only player surface, with no account profile links, attachments or
thread UI. This protects the game-page rendering path; it does not replace
identity projection in other Burrow clients or implement the future game SDK,
voice effects or an operating-system microphone boundary. Do not advertise
universal persona isolation on the strength of this slice.

Create a NEW player-only channel in the game's org. Do not reuse Voltron's
existing development conversation. Its metadata must contain
`{"public_game_slug": "my-game"}`. Set `community_space_id` to that channel ID
in the publication manifest. Without that setting the page says the community
is not open yet. Joining is a CSRF-protected POST, idempotently adding only this
channel. New game identities get an external membership; no internal org role
or DM allowlist is created. Existing internal users retain their role.
The Community tab embeds the player text view after joining. Non-members see
the room introduction and actual member count, not private messages or room
codes. No native game voice client is created. An existing Burrow call can stay
open while the game runs. Browser-only push-to-talk cannot reliably receive
keys while the native game has focus; a future global hotkey bridge is separate
from microphone setup.

## Release and verification

1. Deploy reviewed code and configure the manifest on the serving install.
2. Verify the OIDC provider allows public account creation. This application
   reuses that provider; it does not add its own password store or enable
   provider registration automatically. Set optional `signup_url` to an HTTPS
   registration/invitation link on the configured OIDC issuer host. Only then
   does the page show Create account. That link opens the provider in a new
   tab; after registration players return to the game to sign in. Never claim
   fresh-user onboarding is live until that provider journey has been tested.
3. Open `/games/voltron` in a signed-out mobile browser. The game must be visible
   and download must ask for sign-in. Unpublished slugs must be 404.
4. Use a NEW identity. Sign in and verify return to `/games/voltron`; check only
   external game-org membership exists, with no root/internal membership.
5. Download on Windows and compare the ZIP SHA-256. Confirm the launcher opens.
   A multiplayer match still needs the current private room-code handoff.
6. Explicitly join the player community. Verify only that room is visible;
   development channels, projects and task administration remain inaccessible.
7. Repeat join and sign-in. No duplicate memberships or participants.
8. Verify ordinary web login, native app login and chat attachment access remain
   unchanged. Roll back by clearing the manifest; restart the serving install.

Core checks run on GitHub-hosted CI or the approved test rig, never on the
personal workstation. `Game page smoke` runs the scoped regression suite and
exports formatter changes; the normal CI suite remains authoritative.

## Download and device UI

The orange action progresses from sign-in to download to setup. The browser
shows setup only after the download endpoint acknowledges this exact package
request with a short-lived, non-authentication cookie. This acknowledges the
start of the response, never completion of a file on disk. A missing response
keeps a retry path.

Phone/Mac/Linux detection is advisory. Those visitors can copy the public game
page link, with a visible copy fallback when clipboard access is refused, or
choose the Windows download manually. No email is sent or claimed. Emailing a
link will require a configured sender and the existing audited mail outbox.

UI checks use the actual controller-rendered fixture and compiled CSS/JS on a
GitHub-hosted browser, never a Core browser session on the personal workstation.
