# Published game pages

A public `/games/:slug` page shows a game before sign-in. Burrow OIDC returns
players to the same page; `/games/:slug/releases/:version/download` requires
an active identity and authorizes only the explicitly published artifact.
The chat attachment's original permissions are unchanged.

## Operator publication

Set `GAME_PUBLICATIONS_JSON` on the serving install to a JSON array of manifests.
Absent configuration means no published games. For Voltron, the manifest is:

```json
[{
  "slug": "voltron",
  "published": true,
  "org_id": "01a003e1-3ccf-7df0-b8b3-dbf0c9186a40",
  "title": "Voltron",
  "summary": "Four friends. One giant robot. Walk together, kick cars, and make a spectacular mess.",
  "image_path": "/images/voltron-game.png",
  "image_alt": "A giant Voltron mech above a city street",
  "multiplayer_note": "The server address is included. This build still requires a private room code; automatic Burrow admission is not available yet.",
  "current_version": "61fcce7",
  "releases": [{
    "version": "61fcce7",
    "attachment_id": "01a1b6bd-0935-7000-b72c-23aa0726861d",
    "sha256": "7ed62fb5932c30eac9295e8a67738458e1154ec25c93d2d16c359d900a1fec07",
    "byte_size": 89458340
  }]
}]
```

This is an explicit publication of the portable ZIP, not an installer. Confirm
that it contains no private configs and that the attachment is ready with the
same digest and size. Never put a room code, OIDC credential, user config or
server secret in a manifest. The public page's version and checksum refer to
the ZIP, not its embedded PCK. Retain older version entries when changing the
current pointer; do not repoint a version to different bytes.

## Community

Create a NEW player-only channel in the game's org. Do not reuse Voltron's
existing development conversation. Its metadata must contain
`{"public_game_slug": "voltron"}`. Set `community_space_id` to that channel ID
in the publication manifest. Without that setting the page says the community
is not open yet. Joining is a CSRF-protected POST, idempotently adding only this
channel. New game identities get an external membership; no internal org role
or DM allowlist is created. Existing internal users retain their role.
The Community tab hands off to the existing Burrow chat surface after joining.

## Release and verification

1. Deploy reviewed code and configure the manifest on the serving install.
2. Verify the OIDC provider allows public account creation. This application
   reuses that provider; it does not add its own password store or enable
   provider registration automatically.
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
