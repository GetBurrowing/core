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

## In-app publishing prototype

Root admins can now use **Admin → Games** (`/admin/games`) instead of setting
`GAME_PUBLICATIONS_JSON`. Upload a portable Windows ZIP in Burrow chat first.
Enter its attachment ID, the game org, version, title and summary; save the
release. Its digest and size come from the stored attachment. Publication
creates a fresh, tagged player channel and seats the publisher as admin.
The existing community join, player display-name projection and message
permissions still apply. Existing environment manifests remain fallback only;
a database publication, including an unpublished one, takes precedence.

Versions retain their original bytes. Publish another version to update;
select an older version with its original attachment to roll back. A save
checks all retained attachments and refuses unavailable artifacts or attempts
to change the game org. An archived org cannot receive a new release. This is
install-admin publication for the prototype, not an open game-upload store.

### Windows player

The signed-in game page downloads a **personal** Burrow Player ZIP. Extract it
and run `Play.bat`. Play downloads the current portable release, verifies the
size and SHA-256, stages extraction, and switches the installed version only
on success. Old versions remain installed. A failed update leaves the previous
version playable through **Play installed version**. **Chat / renew sign-in**
opens the same Burrow community in the browser. The first version uses Windows
PowerShell and requires no administrator installation. No native chat or voice
SDK is claimed; browser chat uses the existing signed-in session.

The personal `player.json` contains a game-scoped, download-only bearer grant
valid for seven days. Do not redistribute it; friends get their own player
from the signed-in page. It grants neither account/profile nor chat access,
is rejected for other games, and checks that the identity remains active.
It is never passed to the game. Renew by downloading a fresh player in the
browser. This is not OS isolation from arbitrary code on the same PC.

`/games/:slug/updates` exposes only published release metadata. Native release
downloads require the scoped grant in the Authorization header. Unpublishing
stops new updates and downloads. Already installed copies remain usable.
The release ZIP currently must contain `Play Voltron.bat` at its root.

Hosting here means Burrow-hosted release files plus the existing public ENet
match server. Publishing does not deploy a matching server pack. Coordinate
that separately before advertising public multiplayer; local play works
without it. Fresh-account provider registration still needs to be tested on
the serving install. The publisher does not change the identity provider.

## Gaming presentation for a separate install

The install branding record has an opt-in `experience` value: `workspace`
(default) or `gaming`. Root admins can change it under Admin → Branding.
Only enable it on the gaming install after its owner and initial game are
configured. Existing installs retain their current presentation.

Gaming mode sends the primary app-host root and the installed PWA to `/play`.
The public home uses real published releases and community counts, with a
player-facing identity and an admin-only creator entry. Game pages link back
to that home. Ordinary login and owner handover land in the gaming home;
explicit game login, native login, chat-host and meeting deep links retain
their own routing. An empty publication list has an honest empty state.

This is a presentation choice, not a permission boundary or an identity-sync
service. Existing resource authorization remains in force. A separate
instance has its own database, users and memberships. Reusing an OIDC provider
requires a dedicated client and correct owner binding before first login;
persona, friends and voice preferences do not synchronize automatically.
Do not copy development conversations into the player community.

Voltron's release attachment must be imported into the new install's own
storage and published against a local game org. The original install's
attachment, org and room IDs are not portable database references. Verify the
imported ZIP against its approved digest before publishing. The native match
server can stay shared when the PCK matches; a new web instance does not
require another game-server droplet.
