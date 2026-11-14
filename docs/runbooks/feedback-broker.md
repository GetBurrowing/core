# Feedback broker

Task 01a1a6a5. Burrow installs can file feedback (an agent's `feedback_submit`
tool, and a signed-in person's Send feedback form) as GitHub issues on the
core repository. Installs hold **no GitHub credential and no broker
credential**. They send the sanitized submission to a broker, and the broker
creates the issue with its own GitHub App.

This runbook names environment variables by **key only**. Never paste a
value into a ticket, a chat or a log.

## On an install: opt in

Feedback is **opt-in**. It is off unless the install sets:

| Key | Value | Effect |
| --- | --- | --- |
| `FEEDBACK_POLICY` | `quarantined` (or `trusted`) | Turns on the agent tool, the person form, and intake. Unset, blank, `disabled` or any other value means off. |

Installs rendered by the installer opt in with the manifest's `[feedback] enabled`
(`deployment/schema/install-manifest.md`). It defaults to `install.hosted`, so a hosted install
gets `FEEDBACK_POLICY=quarantined` and a self-hosted one gets nothing unless it sets
`enabled = true`. A hosted install opts out with `enabled = false`. A hosted install picks this
up only once its renderer runs an installer that has the `[feedback]` table; installs provisioned
before that render nothing.

A self-hoster who does not use the installer opts in by setting
`FEEDBACK_POLICY=quarantined` in core's environment.

### Defaults

Once `FEEDBACK_POLICY` is set, an install needs nothing else:

* Repository: `GetBurrowing/core` (`Platform.Feedback.GithubPublisher`).
* Broker: the hosted Burrow broker, `https://<broker host>/api/feedback-broker/v1`.
  The exact value is `Platform.Feedback.GithubPublisher.Broker.default_broker_url/0`,
  the one place in the tree it is written.

### Overrides

| Key | Effect |
| --- | --- |
| `FEEDBACK_BROKER_URL` | Use another broker. An explicit value that is not an `http(s)://host/...` URL makes feedback answer `publisher_not_configured`; it does **not** fall back to the default. |
| `FEEDBACK_REPOSITORY` | Target another `owner/name` repository. The broker must be configured for the same one, or it answers `repository_mismatch`. |
| `FEEDBACK_INSTALLATION_LABEL` | The install's label, shown in the issue's attribution (reduced to `A-Za-z0-9._-`). |

## On the broker host

The broker runs **in core**, behind a flag, on the production install that
`default_broker_url/0` points at. Set these keys in that install's core
environment:

| Key | Purpose |
| --- | --- |
| `FEEDBACK_BROKER_SERVER` | `true` turns on `POST /api/feedback-broker/v1/issues` and `GET /api/feedback-broker/v1/issues/:fingerprint`. Unset, both routes are 404. |
| `FEEDBACK_PUBLISHER` | `github_app`. The broker refuses to run on the `broker` adapter, so it can never forward to another broker. |
| `FEEDBACK_GITHUB_APP_ID` | The GitHub App's id. |
| `FEEDBACK_GITHUB_APP_INSTALLATION_ID` | The App's installation id on `GetBurrowing/core`. |
| `FEEDBACK_GITHUB_APP_PRIVATE_KEY` | The App's private key (PEM). Read from the process environment at call time; never copied into application config. |
| `FEEDBACK_POLICY` | `quarantined`. The broker runs the same `Submission.submit` as an install, which refuses when the policy is off. |
| `FEEDBACK_BROKER_RATE_PER_HOUR` | Optional. Requests per client IP per hour (default 30). |
| `TRUST_PROXY_HEADERS` | Must be `true` behind Cloudflare and Caddy. The per-IP limit keys on `conn.remote_ip` after `PlatformWeb.Plugs.RewriteRemoteIp`. Without it every request carries the proxy's address and all callers share one bucket. With it, forwarding headers are believed only when the immediate peer is in `TRUSTED_PROXIES`; `X-Forwarded-For` is then walked right to left past trusted hops and the first untrusted hop is the client, so a client-supplied leading entry is never used. An unparsable hop fails closed (the peer address is kept). |
| `TRUSTED_PROXIES` | Optional. Comma-separated addresses or CIDRs of the proxies in front of core. Unset, it is loopback plus the private ranges (`127.0.0.0/8`, `::1`, `10.0.0.0/8`, `172.16.0.0/12`, the RFC 1918 /16, `fc00::/7`), which covers a Caddy and cloudflared/tailscale chain on a private network. An explicit value replaces the default, it does not extend it. A bad entry stops boot. |

`CF-Connecting-IP` is honoured only when the first untrusted `X-Forwarded-For` hop is a published Cloudflare edge address; from any other hop, or from an untrusted peer, it is ignored.

Check the chain after any proxy change: two real clients must get separate 429 budgets, and resending with a different forged leading `X-Forwarded-For` entry must not reset a client's budget (the request after the limit still answers 429).

What the broker does with every request, all of which are unauthenticated
and treated as hostile:

* It ignores any top-level `title`, `body` or `labels` and rebuilds the issue
  from `submission` alone: allowlist, redaction, bounds, fenced markdown,
  dedupe by fingerprint, per-IP and installation-wide caps.
* It answers `{repository, issue_number}` (201 created, 200 duplicate) or
  `{"error": <code>}` (422, 429, 502, 503). It never echoes request text,
  headers, GitHub's response or an exception, and both routes are mounted
  with `log: false`.
* On the broker host the broker shares the `feedback_submissions` table, and
  so the installation-wide cap, with that install's own agents and people. This is
  accepted and documented in `Platform.Feedback.BrokerServer`.

## The one infra precondition outside the code

A GitHub App with **issues: write** on `GetBurrowing/core`, installed for the
broker host, whose id, installation id and private key are set as the three
`FEEDBACK_GITHUB_APP_*` keys above. Until it exists the broker answers
`publisher_not_configured` (502) and installs see the same code.

## Moving the broker later

The broker URL is a compile-time default in one place. To move the broker
(for example to `cloud.getburrow.ing`), either change
`@default_broker_url` in `Platform.Feedback.GithubPublisher.Broker` and ship
a release, or set `FEEDBACK_BROKER_URL` on each install. Installs on an older
release keep calling the old default until they upgrade.
