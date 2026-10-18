# GitHub Webhook Secret — Cutover, Verification, Rotation

`POST /api/webhooks/github` fails closed as of task `019f9b11`. This runbook
is how you make sure that is safe on the day it deploys, and how to rotate the
secret afterwards without dropping deliveries.

Read the **Context** and **Step 0** sections before merging. Everything after
that is procedure.

## Context

The endpoint is guarded by `PlatformWeb.Plugs.VerifyGithubSignature`, wired as
`pipeline :github_webhook` in `apps/platform/lib/platform_web/router.ex`. The
plug HMACs the raw request bytes (`conn.assigns[:raw_body]`, cached by
`PlatformWeb.Plugs.CacheBodyReader`) and compares against
`X-Hub-Signature-256: sha256=<hex>`.

`Platform.Webhooks.GithubSignature.secrets_for_repo/1` returns an **ordered
candidate list** and verification succeeds against **any** member:

1. the project row's `deploy_config["webhook_secret"]`, matched on the
   payload's `repository.html_url`; then
2. the app-level `GITHUB_WEBHOOK_SECRET` (wired in `config/runtime.exs`).

Failure returns `401` with `{"status":"error","reason":"<reason>"}` where
reason is one of `missing_signature`, `malformed_signature`,
`no_secret_configured`, `signature_mismatch`, and logs a `[Webhook]` warning
carrying the reason, `x-github-event`, `x-github-delivery`, and `repo_url`.

### Verified pre-fix state (2026-07-25)

Checked against prod, not assumed:

- GitHub hook `602961215` on `Startup-Suite/core` posts to
  `https://suite.example.com/api/webhooks/github`, `content_type: json`,
  events `check_suite`, `pull_request`, `workflow_run`, and **has a secret set**
  (`gh api repos/Startup-Suite/core/hooks/602961215` shows `"secret":"********"`;
  the value is not readable through the API). Every real delivery is already
  signed.
- **No** prod project row carries `deploy_config["webhook_secret"]` — Startup
  Burrow's `deploy_config` holds only `default_deploy_target`,
  `default_strategy`, `deploy_targets`; Soylent' is `%{}`.
- The deployed release has both `Application.get_env(:platform,
  :github_webhook_secret)` and `:github_webhook_signature_required` at `nil` —
  it predates this branch.

So before this fix, every delivery took the controller's `is_nil(secret) ->
conn` bypass: signed by GitHub, never actually verified. **The moment this
branch deploys, an app-level secret that does not match the hook's secret means
every CI/PR delivery 401s platform-wide** — no `ci_passed` evaluation, no
auto-merge, no changelog rows.

### The one piece of good news

`GITHUB_WEBHOOK_SECRET` is **already provisioned** on moon — a 64-hex value in
`/srv/dev/core-ops/secrets/moon-production/platform.secrets.env`, already
injected into the running `core-platform` container's environment. The
deployed release simply never read it.

And it has been **proven equal to the secret GitHub signs with** by replaying
two real deliveries (Step 0). So merge day needs no new secret and no GitHub
rotation: deploy, then confirm. Re-run Step 0 anyway before merging — it costs
a minute and it is the difference between "should be fine" and "verified".

## Step 0 — Prove the two sides already agree (pre-deploy, no rotation)

GitHub will not show you the hook's secret, but it will show you a past
delivery's payload and its `X-Hub-Signature-256`. If our secret reproduces
that signature, the secrets are identical.

The delivery API returns the payload **parsed**, so you must re-serialize it
the way GitHub serialized it: compact separators and **raw UTF-8, not `\uXXXX`
escapes**. Measured on delivery `3833289965823852544`, only one of three
plausible reconstructions matched:

| Reconstruction | Bytes | Matches header |
| --- | --- | --- |
| `json.dumps(p, separators=(',',':'))` (ASCII-escaped) | 26325 | no |
| `json.dumps(p, separators=(',',':'), ensure_ascii=False)` | 26298 | **yes** |
| `json.dumps(p)` (default spacing) | 27040 | no |

`jq -c` has the same escaping problem, plus a worse one: **delivery ids exceed
double precision and jq silently rounds them** (`…965823852544` came back as
`…965823852500`). Pull ids out of the raw JSON with `grep`, never `--jq`.

Run from a checkout with `gh` authenticated:

```bash
# 1. Newest delivery id, without letting jq round it.
ID=$(gh api "repos/Startup-Suite/core/hooks/602961215/deliveries?per_page=1" \
  | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

# 2. Fetch it and rebuild the raw body byte-for-byte.
gh api "repos/Startup-Suite/core/hooks/602961215/deliveries/$ID" > /tmp/d.json
python3 -c "
import json
d = json.load(open('/tmp/d.json'))
h = {k.lower(): v for k, v in d['request']['headers'].items()}
print('expect:', h['x-hub-signature-256'])
open('/tmp/payload.json','w',encoding='utf-8').write(
    json.dumps(d['request']['payload'], separators=(',',':'), ensure_ascii=False))
"

# 3. HMAC it with the prod secret, on moon, without ever printing the secret.
cat /tmp/payload.json | ssh dev@build-host.local "
  SEC=\$(awk -F= '/^GITHUB_WEBHOOK_SECRET=/{print substr(\$0,23)}' \
    /srv/dev/core-ops/secrets/moon-production/platform.secrets.env)
  openssl dgst -sha256 -hmac \"\$SEC\" -hex | tail -1"
```

The hex from step 3 must equal the `expect:` value from step 2 (minus its
`sha256=` prefix). Confirm on a second, different delivery before trusting it.

If it matches: **no cutover is required.** Deploy, then run Step 2.
If it does not match: run Step 1 before or with the merge.

> Access note: use `ssh dev@build-host.local`, not the `ssh hive` alias the LiveKit
> runbook uses. `hive` resolves to the same machine as user `queen`, which has
> no `podman` on `PATH` and cannot read `/srv/dev/core-ops`.

## Step 1 — Cutover / rotation

### 1a. Ordering, and why it is load-bearing

**Env first, verify, then rotate the GitHub side.** Never the reverse: with
GitHub already switched to a value the BEAM does not hold, every delivery in
the gap 401s, and GitHub does not retry 4xx.

Be precise about what dual-accept buys you, because it is easy to over-trust.
The candidate list is *project secret OR app secret* — it is **not** old-value
OR new-value within one slot. Setting `GITHUB_WEBHOOK_SECRET` to a fresh value
while GitHub still signs with the old one breaks deliveries just as badly, in
the other direction. A truly zero-gap rotation uses **both slots** (1b).

### 1b. Zero-gap rotation (preferred)

Park the outgoing secret in the per-project slot so both values verify while
GitHub catches up.

```bash
NEW=$(openssl rand -hex 32)   # store in the ops vault before going further
```

1. **Pin the current value into the project row.** On moon, with `OLD` being
   whatever `GITHUB_WEBHOOK_SECRET` is today:

   ```bash
   ssh dev@build-host.local "podman exec core-platform /app/bin/platform rpc '
     project = Platform.Repo.get_by(Platform.Tasks.Project,
       repo_url: \"https://github.com/Startup-Suite/core\")
     {:ok, _} = Platform.Tasks.update_project(project, %{
       deploy_config: Map.put(project.deploy_config || %{}, \"webhook_secret\", \"OLD\")})
     IO.puts(\"pinned\")'"
   ```

2. **Set the new value in the env file** —
   `GITHUB_WEBHOOK_SECRET=$NEW` in
   `/srv/dev/core-ops/secrets/moon-production/platform.secrets.env` —
   and restart:

   ```bash
   ssh dev@build-host.local "systemctl --user restart core-platform"
   ```

3. **Verify the BEAM holds a secret** (prints `true`, never the value):

   ```bash
   ssh dev@build-host.local "podman exec core-platform /app/bin/platform rpc '
     IO.puts(is_binary(Application.get_env(:platform, :github_webhook_secret)))'"
   ```

   Both `OLD` (project row) and `NEW` (env) now verify.

4. **Rotate the GitHub side:**

   ```bash
   gh api --method PATCH repos/Startup-Suite/core/hooks/602961215 \
     -f 'config[secret]='"$NEW" \
     -f 'config[url]=https://suite.example.com/api/webhooks/github' \
     -f 'config[content_type]=json'
   ```

   `config` is replaced wholesale on PATCH — resend `url` and `content_type`
   or you will blank them.

5. **Confirm** with Step 2, then **remove the parked old value**:

   ```bash
   ssh dev@build-host.local "podman exec core-platform /app/bin/platform rpc '
     project = Platform.Repo.get_by(Platform.Tasks.Project,
       repo_url: \"https://github.com/Startup-Suite/core\")
     {:ok, _} = Platform.Tasks.update_project(project, %{
       deploy_config: Map.delete(project.deploy_config, \"webhook_secret\")})
     IO.puts(\"cleared\")'"
   ```

   Leaving it parked is not dangerous, but it is a stale credential and the
   next operator will not know which of the two is live.

### 1c. Single-slot rotation (only if 1b is unavailable)

Env → restart → verify → PATCH GitHub, accepting a gap between the restart and
the PATCH in which GitHub signs with the old value and the BEAM rejects it.
Keep the gap to seconds, or hold the flag off (Step 3) across it and turn it
back on immediately after. Prefer 1b.

## Step 2 — Confirm

Redeliver a real delivery and watch both ends.

```bash
# Newest check_suite delivery id (grep, not --jq — see Step 0).
ID=$(gh api "repos/Startup-Suite/core/hooks/602961215/deliveries?per_page=10" \
  | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

gh api --method POST \
  "repos/Startup-Suite/core/hooks/602961215/deliveries/$ID/attempts"
```

The hook UI's **Redeliver** button does the same thing and shows the response
inline.

Expected:

- **HTTP 200** (or 201 when the delivery flips a pending `ci_passed`
  validation). `{"status":"ignored", ...}` with a 200 is a pass — it means the
  signature verified and the controller simply had no live task for that
  branch. Verification happened before any controller code ran.
- **No** `[Webhook] Rejecting GitHub webhook` warning in the log.

```bash
ssh dev@build-host.local "podman logs --since 5m core-platform 2>&1 | grep '\[Webhook\]'"
```

A `[Webhook] Evaluated ci_passed validation … as passed` line appears only when
the delivery matched a task's pending validation; its absence is not a failure
signal on a redelivered old event.

Failure looks like:

```
401 {"status":"error","reason":"signature_mismatch"}
[Webhook] Rejecting GitHub webhook: signature verification failed
  (reason=signature_mismatch x-github-event="check_suite"
   x-github-delivery="…" repo_url="https://github.com/Startup-Suite/core")
```

`signature_mismatch` = the two values diverged (go back to Step 1).
`no_secret_configured` = the BEAM has neither candidate; the env var is missing
or the release did not pick it up. `missing_signature` = the hook has no secret
set at all on the GitHub side.

## Step 3 — Rollback valve (read this before using it)

```bash
ssh dev@build-host.local "podman exec core-platform /app/bin/platform rpc \
  'Application.put_env(:platform, :github_webhook_signature_required, false)'"
```

This reopens `/api/webhooks/github` in-BEAM with no redeploy: verification
still runs and still logs, but failures pass through instead of halting.

**It restores the exact vulnerability this task was filed to close.** With the
flag off, anyone who can reach the URL can post a forged
`check_suite.completed` naming any `task/<id>` branch and flip that task's
`ci_passed` validation to `passed` — which can cascade into an automatic merge.
There is no authentication left on the endpoint. This is not a "reduced
security" mode; it is an open door.

Rules for using it:

- Turn it back on **in the same session**, not "later today":

  ```bash
  ssh dev@build-host.local "podman exec core-platform /app/bin/platform rpc \
    'Application.put_env(:platform, :github_webhook_signature_required, true)'"
  ssh dev@build-host.local "podman exec core-platform /app/bin/platform rpc \
    'IO.puts(Application.get_env(:platform, :github_webhook_signature_required))'"
  # expected: true
  ```

- While it is off, every passed-through delivery logs
  `… — passing through because :github_webhook_signature_required is false`.
  That line is the alarm; if it is in the log, the door is open:

  ```bash
  ssh dev@build-host.local "podman logs --since 15m core-platform 2>&1 | grep 'passing through'"
  ```

- The override is in-BEAM only. A restart reverts to the `config.exs` default
  of `true`. That is a safety property, not a bug: if you are unsure whether
  someone left it off, restarting closes it.

## Step 4 — Per-project secrets for other repos

Any repo can carry its own secret instead of using the app-level fallback.
Matching is on **exact** `repo_url` against the payload's
`repository.html_url`. Set it from the prod console:

```elixir
project = Platform.Repo.get_by(Platform.Tasks.Project,
  repo_url: "https://github.com/Soylent/SoylentMVP")

Platform.Tasks.update_project(project, %{
  deploy_config: Map.put(project.deploy_config || %{}, "webhook_secret", secret)
})
```

Then set the same value on that repo's hook (`gh api --method PATCH
repos/<owner>/<repo>/hooks/<id> -f 'config[secret]=…'`, resending `url` and
`content_type`). If a project has no per-project secret, its deliveries fall
back to `GITHUB_WEBHOOK_SECRET`; if neither exists, they 401 with
`no_secret_configured` — an unconfigured repo fails closed rather than being
waved through.

Note that `repository.html_url` comes from the payload and is therefore
attacker-controlled, so *which* project secret gets tried is
attacker-influenced. That is safe: no candidate is ever skipped, and forging
the field can only widen the candidate list — verification still requires
possessing one of the secrets.

## Related

- `apps/platform/lib/platform_web/plugs/verify_github_signature.ex` — the plug.
- `apps/platform/lib/platform/webhooks/github_signature.ex` — verdict logic and
  candidate resolution.
- `apps/platform/lib/platform_web/router.ex` — `pipeline :github_webhook`.
- `apps/platform/config/config.exs` — `:github_webhook_signature_required` default
  (`true`).
- `apps/platform/config/runtime.exs` — `GITHUB_WEBHOOK_SECRET` wiring.
- `deployment/templates/platform.secrets.env.example` — documents the key; real
  values live in the private ops repo on moon.
- [`livekit_key_rotation.md`](livekit_key_rotation.md) — the sibling procedure
  for `/api/webhooks/livekit`. Its dual-accept gap is real; note that its
  `ssh hive podman …` invocations do not work as written from the current host
  layout (see the access note in Step 0).
