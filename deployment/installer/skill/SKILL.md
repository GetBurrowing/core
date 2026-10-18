---
name: burrow-install-mac
description: Install Burrow, self-hosted, on this Mac (Docker Desktop or OrbStack, reached through a Cloudflare tunnel) by driving the deterministic `burrow-install setup` CLI. Use when the user asks to install, set up, resume, repair or check a Burrow install on a Mac.
---

# Install Burrow on this Mac

You drive one program, `burrow-install`, which lives at
`deployment/installer/mac/burrow-install` in the Burrow core checkout. Every
command prints ONE JSON document. The CLI holds all the logic: it decides what
is done, what is next, and what it needs. This skill only adds conversation.
Do nothing to the machine that the CLI does not do.

## Start by offering

Open with an offer, in your own words, along these lines:

> Want me to set up Burrow on this Mac? I'll do the work. I need a few things
> from you along the way:
> - a domain in a Cloudflare account you control (for example `example.com`);
> - a Cloudflare API token with Zone:Read, DNS:Edit and Account: Cloudflare Tunnel:Edit;
> - an OpenAI API key (Burrow's memory search uses OpenAI embeddings);
> - the Docker Hub read credential for Burrow's images (a small JSON file; ask
>   whoever gave you access to Burrow);
> - your email address, for the first admin account;
> - at the end, about a minute to add a passkey in your browser.
>
> Docker Desktop or OrbStack needs to be installed and running. Installing it
> needs your Mac admin password, so that part is yours.

If they say yes, go ahead and drive the whole flow yourself. Ask only for what
the CLI says it needs, when it needs it.

## Rules

- **Secrets never enter this conversation.** Never ask the user to paste a key,
  token or password into chat. Never put one on a command line. Never read,
  `cat`, print or summarise `secrets.env`, `customer-secrets.env`, anything in
  `secrets/`, a key file, or `.setup/login-link`.
- **Keychain first:** for a secret input, run `burrow-install setup secret NAME`.
  It opens a native macOS dialog with hidden input. The user pastes the value
  there and the CLI stores it in their login Keychain under
  `suite-install.<install name>`. You only ever see the input's name and length.
- **File fallback** (no dialog possible, e.g. over ssh): ask the user to save
  the value to a file only they can read, e.g. `~/.burrow-secrets/OPENAI_API_KEY`
  with `chmod 600`, and give only the PATH:
  `burrow-install setup run <step> --input OPENAI_API_KEY=@/Users/<them>/.burrow-secrets/OPENAI_API_KEY`.
  The CLI refuses a literal secret on the command line (`secret_in_argv`) and a
  file other people can read (`secret_file_permissions`).
- **Non-secret inputs** (`ADMIN_EMAIL`, `ADMIN_USERNAME`) can be passed as
  literals: `--input ADMIN_EMAIL=them@example.com`.
- Change the install only with `burrow-install setup init` flags. Never edit
  `install.toml`, `compose.yaml` or any other file by hand.
- **Stop and hand back to the human** for anything that needs sudo, a security
  decision (FileVault, automatic login), their router (port forwards), or their
  browser (passkey). Say exactly what to do, then wait.

## The loop

1. Create the install once:
   `burrow-install setup init --from deployment/examples/mac-lite.install.toml --name <short-name> --domain <burrow hostname> --registry <registry path, e.g. ghcr.io/owner>`
   Use `mac.install.toml` instead if they want meetings. The registry path
   is whoever publishes their Burrow images; there is no default, so ask
   whoever gave them access. `mac.install.toml` still uses the legacy
   `[images] image_namespace` input (meeting-transcriber has no registry
   build yet); pass `--image-namespace <Docker Hub namespace>` with it instead.
   Keep every hostname exactly ONE label below the Cloudflare zone. With the
   zone `example.com`, use `--domain burrow.example.com --auth-host auth-burrow.example.com`,
   not `auth.burrow.example.com`. Cloudflare's free certificate covers only one
   level, and the `domain` step refuses deeper names with `hostname_too_deep`,
   naming the flat alternative.
2. Run `burrow-install setup status --json`. Read `next_step`, then each step's
   `state` (`done`, `pending` or `blocked`), `needs` and `blocked_reason`.
3. If the next step `needs` inputs, get exactly those from the user (see
   "Inputs" below).
4. Run `burrow-install setup run <next_step>`.
5. Read the result:
   - `"ok": true`: continue. Show the user anything under `human_steps`.
   - exit 2 (`step_order`, `secret_in_argv`, `usage`): you called it wrong.
     Follow the `remediation`.
   - exit 3 (`input_missing`, `awaiting_passkey`): a human is needed. Tell them
     what the `remediation` says.
   - exit 1: explain `error_code` and `remediation` in plain words. Fix what you
     can by re-running, and ask the human for the rest.
6. Repeat until `status` reports `"complete": true`.

Changing a knob later, for example turning meetings off:
`burrow-install setup init --dir <install dir> --meetings off`, then carry on
with the loop. The loop re-runs `tunnel`, `render` and `up`, and secrets are
kept.

## Inputs

| Input | How to get it |
|---|---|
| `CLOUDFLARE_API_TOKEN` | Cloudflare dashboard > My Profile > API Tokens > Create Token (custom): Zone:Read, DNS:Edit, Account: Cloudflare Tunnel:Edit. Then `burrow-install setup secret CLOUDFLARE_API_TOKEN`. |
| `OPENAI_API_KEY` | platform.openai.com > API keys. Then `burrow-install setup secret OPENAI_API_KEY`. |
| `REGISTRY_AUTH` | A docker `config.json` holding a Docker Hub read token for Burrow's private images. The user gets it from whoever gave them access. Then `burrow-install setup secret REGISTRY_AUTH` (paste the JSON), or save it 0600 and pass `--input REGISTRY_AUTH=@<path>`. |
| `ADMIN_EMAIL` | Just ask. `--input ADMIN_EMAIL=<email>` |
| `ADMIN_USERNAME` | Optional. The default is the part of the email before `@`. |

## The steps

- `burrow-install setup run preflight`: read-only. It checks the container
  runtime is running, compose, disk, RAM, the ports meetings would use, and
  that the registry credential can pull. Relay its licence line: Docker Desktop
  and OrbStack have paid tiers for larger commercial use. Stop on
  `runtime_not_running` and ask the user to start Docker Desktop or OrbStack.
- `burrow-install setup run domain`: finds the Cloudflare zone and checks the
  token and the hostname depth.
- `burrow-install setup run tunnel`: creates the Cloudflare tunnel and DNS
  records. It needs no router changes.
- `burrow-install setup run ddns`: only for meetings with `media_reach = "public"`.
  Relay the router port-forward in `human_steps`; that is the user's job.
- `burrow-install setup run render`: writes the install files.
- `burrow-install setup run up`: starts everything, waits for it to be healthy,
  then creates the first admin account straight away (it needs `ADMIN_EMAIL`).
  The first run downloads several GB.
- `burrow-install setup run pocket-id`: enrols the admin's passkey. It opens a
  one-time sign-in link in the user's browser itself; you never see the link.
  Tell the user: "A browser window opened, signed in to the Burrow sign-in
  service. On the Account page, choose Add passkey and follow your Mac's
  prompt (Touch ID or your password). Tell me when it's done." Then re-run
  `burrow-install setup run pocket-id`. It reports `done` once a passkey exists.
  If `browser_opened` is false, tell the user to open the link saved in the
  `login_link_file` path themselves. Do not open or read that file.
- `burrow-install setup run oidc-client`: connects Burrow's sign-in to pocket-id.
- `burrow-install setup run keepalive`: advisory, and it never blocks the
  install. Relay each `human_steps` entry. The `sudo pmset` command needs the
  owner's password, so they run it, not you. Relay `power_failure_truth` word
  for word: with FileVault on, a power cut leaves the Mac waiting at the unlock
  screen and Burrow stays down until someone logs in. Turning FileVault off is
  their security decision. Never suggest it as the default.
- `burrow-install setup run backup`: sets up the nightly database backup (03:15,
  kept 14 days, in `~/BurrowBackups`) and runs it once.
- `burrow-install setup run verify`: checks `https://<domain>/health`, the
  sign-in redirect and the sign-in page over the public internet. When it
  passes, tell the user to open `https://<domain>/` and sign in with their
  passkey.

## Managing users after the install

Burrow admins add, disable and remove the people who can sign in at
`https://<domain>/admin/sign-in-users`. Each new person gets a one-time
sign-in link (valid 30 minutes) that the admin passes on to them. Only Burrow
admins see that page. If it cannot reach pocket-id, pocket-id's own admin
screen at `https://<auth host>/settings/admin` is the fallback.

## Other commands

- `burrow-install setup status --json`: where things stand; safe at any time.
- `burrow-install setup teardown --confirm <install name>`: deletes the
  containers and their data, the background jobs, the tunnel and its DNS
  records. Only on an explicit request from the user, after you have said in
  plain words that it deletes the data (backups in `~/BurrowBackups` stay).
