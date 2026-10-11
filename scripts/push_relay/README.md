# Push relay dev rig (task 01a1261e)

A three-server rig for exercising the Burrow push relay end to end. **Dev
only. Never production, and real APNs/FCM credentials never go into it.**

## Pieces

| Server | Role | Key config |
|---|---|---|
| **R** (relay) | dev server from the task branch, own DB | `PUSH_RELAY_SERVER=true`; APNs `base_url` at an h2c recording stub with a THROWAWAY `.p8` and topic `com.kobo-ai.burrow`; FCM `base_url` / `token_url` at `clients/android/scripts/e2e/fcm_stub.py` with the throwaway key it writes (`--make-key`) |
| **capture proxy** | `scripts/push_relay/capture_proxy.py` in front of R | `--upstream <R url> --record relay-capture.jsonl` |
| **A**, **B** (installs) | dev servers with distinct `APP_URL` hosts (`suite-a.localhost`, `suite-b.localhost`) and their own DBs | NO direct APNs/FCM config; `PUSH_RELAY_URL=<proxy url>`, `PUSH_RELAY_CREDENTIAL=<their own credential>` |
| **C** (optional) | a direct-push install, `suite-c.localhost` | direct APNs (the same h2c stub, throwaway `.p8`) and direct FCM (`fcm_stub.py`); NO `PUSH_RELAY_URL` |

## Steps

1. Start R with relay mode on and its stub-pointed provider config, e.g.

   ```elixir
   # R's dev config, never committed
   config :platform, :push_relay_server, enabled: true
   config :platform, :apns,
     key_id: "THROWAWAY1", team_id: "THROWAWAY1", topic: "com.kobo-ai.burrow",
     auth_key: File.read!("throwaway.p8"), base_url: "http://127.0.0.1:<h2c stub port>"
   config :platform, :fcm,
     service_account: File.read!("<fcm_stub --make-key output>"),
     base_url: "http://127.0.0.1:<fcm stub port>",
     token_url: "http://127.0.0.1:<fcm stub port>/token"
   ```

   The APNs Finch pool is HTTP/2 only, so the APNs stub must speak h2c
   (cleartext HTTP/2) and record each request body. Generate the throwaway
   `.p8` locally (any P-256 key in PKCS#8 PEM); Apple never sees it.

2. Register each install ON R; each credential is printed once:

   ```sh
   mix platform.push_relay_install --name "A" --host suite-a.localhost
   mix platform.push_relay_install --name "B" --host suite-b.localhost
   ```

3. Start the capture proxy:

   ```sh
   python3 scripts/push_relay/capture_proxy.py --listen 127.0.0.1:4100 \
     --upstream http://127.0.0.1:<R port> --record relay-capture.jsonl
   ```

4. Start A and B with `PUSH_RELAY_URL=http://127.0.0.1:4100` and their own
   `PUSH_RELAY_CREDENTIAL`. Leave every `APNS_*` / `FCM_*` variable unset on
   them: direct credentials always win over the relay.

5. Sign the sim/emulator in to A and B. Check that each `apns_devices` /
   `fcm_devices` row has a non-null `push_public_key`.

## What to look at

* `relay-capture.jsonl`: one line per install->relay request. Every item's
  keys are a subset of `platform, token, environment, install_host,
  unread_count, unread_as_of, sealed, collapse_id`.
* The stubs' recordings: the APNs body is the constant alert
  (`Burrow` / `New notification`, `mutable-content: 1`) plus
  `install_host`, `unread_count`, `unread_as_of` and `sealed`. The FCM
  message is data-only.
* R's log: one `[PushRelay] install <id> batch=...` line per request, with
  counts only.
* R's database: `push_relay_installs` is the only table relay mode writes.

## Not covered

VoIP (PushKit ringing) does not go through the relay. Relay-mode installs
get no CallKit ring; the `meeting_ring_*` alert kinds still flow.
