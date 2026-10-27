# Tab-switch baseline (task 01a17b00 stage 1)

What a tap on an app tab costs today, per tab, before `/live` websocket
compression is enabled (stage 2). Stage 2 re-runs the same harness on the same
fixture, so the wire-bytes columns can be compared on/off.

- **Commit measured:** `709747d4c` (origin/main at planning). The task branch
  adds only the harness, the fixture seed and the tests, with no app code.
- **Data source:** every row is **local seeded**. No exp rows yet. Exp needs a
  test account (asked for in the execution space). Until then exp is
  not measured, and nobody has signed in to exp any other way.
- **Machine:** Apple M4 (10 cores, 16 GB), macOS (Darwin 25.3.0), headless
  Chrome 156.0.8078.48, dev server (`MIX_ENV=dev`, code reloading on) on
  loopback. Postgres 16 runs in the local docker container.
- **Raw data:** `docs/perf/tab-switch-baseline.data.json` (every tap, every
  server mount).

## Method

**Fixture.** `apps/platform/priv/scripts/seed_tab_switch_fixture.exs` writes
into a per-task dev database. It refuses to run unless `MIX_ENV=dev` and the
database name carries the task suffix, and it checks this before the app
boots. It creates:

- the busy channel `tab-switch-busy`: 2,000 messages (200 of them thread
  replies across 40 threads, 45 with attachments), 300 reactions and 10 pins;
- 22 more channels the test user sits in;
- 4 projects with 12 epics and 320 tasks spread over 7 board statuses, plus a
  stored tasks project pref (S1);
- 40 inbox mentions;
- 24 meetings.

The test user is `/dev/login?as=tabswitch`.

**Driver.** `e2e/scripts/measure-tab-switch.sh` runs `measure-tab-switch.mjs`
(Playwright over CDP). It launches its own headless Chrome on its own port and
profile. It reads the tabs off the rendered desktop sidebar (`#sidebar-nav`
plus `/settings`), which renders `IconRail.destinations/1`, and cross-checks
them against `destinations/1` on the node.

On this install Email is switched off (`Platform.Mail.Config.enabled?/0` is
false) and Games is off, so neither is a tab here. Admin and Prompts are
root-only and are not tabs for a member.

For each tab the driver:

1. Opens the origin page with a full load. The origin is the busy channel for
   every tab except chat, which starts from `/inbox`.
2. Taps the real sidebar `<.link navigate>` 11 times. The first tap warms up
   and is discarded. After each tap the driver returns to the origin with an
   unmeasured navigate.
3. Times the taps in the page clock:
   - **ready ms**: the tap's `click` event timeStamp until all three of these
     hold: `phx:page-loading-stop` has fired, the new `[data-phx-main]` (a
     different element from the old one) has `.phx-connected`, and the probe
     element exists.
   - **tap-to-interactive ms**: the tap until the probe takes a keystroke. For
     chat the driver types `x` into the composer `#compose_text` and waits for
     its `input` event. For tasks it does the same with the task search
     `#task-search`. Every other tab, and any text probe that is not rendered
     (tasks on a phone), uses a Tab-key probe: focus starts at the new main
     LiveView, Tab is pressed, and the driver waits for `focusin` inside it.
     The gap between ready and tap-to-interactive (about 5 to 80 ms) is the
     CDP keystroke round trip plus the browser handling the key.
4. Measures bytes:
   - **raw bytes**: the `phx_reply` to the new main LiveView's `phx_join`, from
     CDP `Network.webSocketFrameReceived`. CDP shows the decompressed text.
   - **wire bytes**: the server-to-client TCP payload bytes on the `/live`
     websocket from the tap to ready. A byte-counting proxy between Chrome and
     the dev server records them. They include WebSocket framing and every
     frame in the window (the join reply, the diffs that follow it, presence).
   - **deflate est.**: the same window's frames raw-deflated (window 15,
     context takeover within the window only, sync-flush tail stripped). This
     is a forecast for stage 2 and for exp, not a measurement.

   Chrome offered `permessage-deflate` on every connection and the server
   declined it every time. The proxy logs the 101 response, so the wire column
   here is uncompressed.
5. Reads the server side through `e2e/scripts/tab_switch_probe.exs`. This is a
   dev-only module that the driver loads into the running dev node over Erlang
   distribution. It is not in any config or in `lib/`. It records, per arriving
   LiveView process:
   - mount and handle_params durations, from
     `[:phoenix, :live_view, :mount | :handle_params, :stop]`;
   - the Repo query count from mount start to the first handle_event;
   - `refresh_board` spans;
   - `count_by_scope/1` calls, and the project scope of each
     `list_all_tasks/1` call (call tracing).

   It keeps module names, durations and counts only. The driver also sets the
   dev node's Logger to `:info`, prod's level. At `:debug` every query is
   formatted and streamed to the live-reload socket, which inflates both
   server time and CDP frame counts.

Each tab was capped at 5 minutes and each batch at 25 to 30 minutes. A tab that
times out has Chrome killed and restarted. That happened once: voice's first
probe, `#ctx-search`, turned out to sit inside the closed "Talking about"
sheet. Voice was re-run with the Tab-key probe.

## Per tab (desktop 1280x800, local seeded, N = 10)

Each cell is median / p90. Server columns are for the arriving LiveView only.
Bytes are KiB.

| tab | path | view | mount ms | handle_params ms | queries | raw join reply | wire (proxy) | deflate est. | ready ms | tap-to-interactive ms | probe |
|---|---|---|---|---|---|---|---|---|---|---|---|
| chat (busy space) | `/chat` -> `/chat/tab-switch-busy` | ChatLive | 30.5 / 31.4 | 31.8 / 34.8 | 250 / 250 | 313.4 / 313.4 | 342.4 / 342.4 | 34.8 / 34.8 | 185 / 189 | **233 / 245** | composer |
| voice | `/voice` | VoiceLive | 20.6 / 21.9 | 0.0 / 0.0 | 80 / 80 | 65.3 / 65.3 | 76.5 / 76.5 | 12.5 / 12.5 | 60 / 67 | 66 / 71 | Tab key |
| tasks (S1) | `/tasks` | TasksLive | 16.6 / 20.8 | 8.2 / 9.3 | 105 / 105 | 190.5 / 190.5 | 203.1 / 203.1 | 25.6 / 25.6 | 104 / 112 | **127 / 138** | task search |
| tasks (S2) | `/tasks` | TasksLive | 15.5 / 18.3 | 8.5 / 8.8 | 101 / 101 | 432.6 / 432.6 | 445.2 / 445.2 | 41.1 / 41.1 | 180 / 195 | **260 / 272** | task search |
| meetings | `/meetings` | MeetingLive | 15.0 / 16.4 | 2.8 / 3.8 | 82 / 82 | 71.2 / 71.2 | 84.0 / 84.0 | 12.9 / 12.9 | 59 / 63 | 66 / 70 | Tab key |
| inbox | `/inbox` | InboxLive | 16.1 / 17.0 | 4.4 / 4.7 | 90 / 90 | 57.5 / 57.5 | 68.7 / 68.7 | 11.1 / 11.1 | 54 / 61 | 61 / 64 | Tab key |
| files | `/files` | FilesLive | 20.8 / 24.0 | 4.1 / 4.9 | 90 / 90 | 78.3 / 78.3 | 89.5 / 89.5 | 12.9 / 12.9 | 64 / 72 | 71 / 80 | Tab key |
| canvases | `/files?tab=browse&type=canvas` | FilesLive | 20.3 / 21.2 | 3.5 / 3.9 | 89 / 89 | 79.2 / 79.2 | 90.3 / 90.3 | 13.1 / 13.1 | 66 / 70 | 74 / 78 | Tab key |
| skills | `/skills` | SkillsLive | 17.0 / 18.2 | 0.0 / 0.0 | 75 / 75 | 51.6 / 51.6 | 62.7 / 62.7 | 10.1 / 10.1 | 50 / 57 | 56 / 64 | Tab key |
| org_memory | `/org_memory` | OrgMemoryLive | 17.1 / 18.5 | 0.0 / 0.0 | 76 / 76 | 65.1 / 65.1 | 76.7 / 76.7 | 12.1 / 12.1 | 47 / 54 | 56 / 58 | Tab key |
| control | `/control` | ControlCenterLive | 22.0 / 24.3 | 5.5 / 6.5 | 130 / 130 | 60.4 / 60.4 | 71.6 / 71.6 | 12.0 / 12.0 | 68 / 72 | 73 / 80 | Tab key |
| experiments | `/control/experiments` | ExperimentsLive | 15.8 / 17.2 | 1.2 / 2.1 | 79 / 79 | 56.4 / 56.4 | 67.6 / 67.6 | 11.2 / 11.2 | 52 / 60 | 62 / 66 | Tab key |
| changelog | `/changelog` | ChangelogLive | 16.7 / 19.2 | 0.0 / 0.1 | 75 / 75 | 51.2 / 51.2 | 62.3 / 62.3 | 9.9 / 9.9 | 52 / 67 | 64 / 70 | Tab key |
| settings | `/settings` | SettingsLive | 16.3 / 17.2 | 0.0 / 0.0 | 75 / 75 | 61.1 / 61.1 | 75.0 / 75.0 | 11.3 / 11.3 | 55 / 63 | 62 / 66 | Tab key |

Notes on reading the table:

- A handle_params of 0.0 means the view has no `handle_params/3`.
- The chat tab's `/chat` link lands on the last-visited space, here the busy
  channel.
- Raw bytes did not change across the ten taps (p90 equals median), so the
  join reply's size is a property of the page, not noise.
- **Chat and tasks are the outliers.** Every other tab is interactive in 56 to
  74 ms with a 51 to 79 KiB join reply. Chat's join reply is 313 KiB and tasks'
  is 190 KiB (S1) or 433 KiB (S2). Their tap-to-interactive is 2 to 4 times
  that of the other tabs.
- **Where the time goes.** For chat, server mount plus handle_params is about
  62 ms of a 233 ms tap. For tasks S2 it is about 24 ms of 260 ms. Most of
  the rest happens after the server's work: shipping and applying a 0.3 to
  0.4 MiB diff, from page-loading-stop to ready. On loopback the transfer time
  itself is near zero, so these numbers are a floor. On a real network the
  bytes matter more.
- **Expected effect of compression.** The deflate estimate for these join
  replies is 9 to 11 times smaller than the raw bytes (chat 313 to 35 KiB;
  tasks S2 433 to 41 KiB). That is a forecast. Stage 2 measures it on the wire
  with the same proxy.

## Tasks tab: chat -> tasks arrival (folds in 01a166be)

Task 01a166be's fix shipped in #1341. On new main that is
`86620c37f17a34fc7eb8b3966d3ae4b874380e05`, found by subject; it is the same
sha as on the old repo. The fix is `defer_board/1`, one `count_by_scope/1` per
refresh, and the `[:platform_web, :tasks, :refresh_board]` span. These rows
measure an arrival from the busy channel with the real browser, per arrival,
N = 10:

| scenario | viewport | refresh_board | count_by_scope | first board load | handle_params calls | Repo queries | mount ms | raw join reply KiB | tap-to-interactive ms |
|---|---|---|---|---|---|---|---|---|---|
| S1 stored project | 1280x800 | 1 | 1 | narrowed (one project, all epics) | 1 | 105 | 16.6 / 20.8 | 190.5 | 127 / 138 |
| S2 no stored project (`?project=all`) | 1280x800 | 1 | 1 | widest (all projects) | 1 | 101 | 15.5 / 18.3 | 432.6 | 260 / 272 |
| S2 no stored project | 390x844 | 1 | 1 | widest (all projects) | 1 | 101 | 27.3 / 35.7 | 450.5 | 213 / 233 (Tab-key probe) |
| S1 stored project | 390x844 | 1 | 1 | narrowed | 1 | 105 | 28.0 / 38.5 | **INCONCLUSIVE** | **INCONCLUSIVE** |

- **The 01a166be fix holds in a real browser.** Every arrival ran exactly one
  board load and one `count_by_scope`. S1's first load is already narrowed to
  the stored project, so there is no widest-first pass followed by a narrowed
  one. S2 loads all projects once, which is what it asks for.
- **S2 costs twice what S1 does.** With no stored project the board ships
  every task: a 433 KiB join reply against 190 KiB, and 260 ms to interactive
  against 127 ms. The cost is board size, not extra loads.
- **Query counts are above the budget test's thresholds** (`@main_s1_queries`
  60, `@main_s2_queries` 48 in `tasks_live_switch_budget_test.exs`). That is
  expected and is not a regression signal: the budget test runs a 10-task
  fixture with a user in one space, while this user sits in 24 spaces with a
  320-task board. The per-arrival budget test still passes unchanged (see
  validations).
- **handle_params ran once per arrival in the browser.** In LiveViewTest the
  pin's replace patch re-enters handle_params, so the budget test sees 2. In
  the browser the arrival URL already carries `?project=` by then, so the
  probe sees 1. The board-load count is 1 either way.
- **Phone S1 is INCONCLUSIVE.** In both phone S1 runs the first `/live`
  websocket upgrade got no `101` through the proxy. LiveView then fell back to
  long-poll for the whole session, so no websocket frames exist to measure,
  and the 0.3 to 5 s taps are long-poll timings, not a tab-switch cost. The
  phone S2 run between those two S1 runs was normal. This rig has not
  established the cause. The runs stay in the data file, flagged
  `websocket_join_every_tap: false`, and are not reported as numbers. The
  server-side columns (one load, one count_by_scope, narrowed, 105 queries)
  come from the node, not the socket, so they stand.

## Not measured yet

- **Exp rows.** These need the test account. Once it exists, run:

  ```
  e2e/scripts/measure-tab-switch.sh --base-url https://<the exp node> --no-proxy \
    --auth-state <state> --label exp --out <file>
  ```

  On exp, wire bytes can only be the deflate estimate (TLS, no proxy). Server
  mount time is "unavailable" unless an ordinary account can open
  LiveDashboard, and it will not be guessed.
- **Phone tabs other than tasks.** The driver taps the first visible link
  for each tab and opens no More sheet, so phone runs cover tab-bar entries
  only. Of those, only tasks was run.

## Reproduce

```
cd apps/platform
PLATFORM_DEV_DATABASE=platform_dev_01a17b00 MIX_ENV=dev \
  mix run --no-start priv/scripts/seed_tab_switch_fixture.exs        # S1; add --no-project-pref for S2
PLATFORM_DEV_DATABASE=platform_dev_01a17b00 PORT=<port> MIX_ENV=dev \
  elixir --name <node>@127.0.0.1 --cookie "$(cat <cookie-file>)" -S mix phx.server
cd ../..
e2e/scripts/measure-tab-switch.sh --base-url http://localhost:<port> --login-as tabswitch \
  --node <node>@127.0.0.1 --cookie-file <cookie-file> --out <results.json> [--tabs tasks] \
  [--viewport 390x844] [--tasks-scenario S2]
```

## Stage 2: permessage-deflate on `/live` (task 01a17b00)

**Change.** `compress: true` in the `/live` socket's `websocket:` opts in
`apps/platform/lib/platform_web/endpoint.ex`. `/runtime/ws` and `/agent-host`
are unchanged: there is no measurement of them in this task, so no reason to.

### The compress path in deps (read, not assumed)

- `deps/phoenix/lib/phoenix/transports/websocket.ex:33` defaults
  `compress: false`. That is why Chrome's offer was declined in stage 1.
- `deps/phoenix/lib/phoenix/transports/websocket.ex:79` passes the socket's
  websocket opts to `WebSockAdapter.upgrade(handler, arg, opts)`.
- `deps/websock_adapter/lib/websock_adapter.ex:73` (`tuple_for(Bandit.Adapter, ...)`)
  hands the opts through untouched to Bandit (the cowboy clause at :84 maps
  `compress` explicitly; not used here).
- `deps/bandit/lib/bandit/pipeline.ex:155` calls
  `Bandit.WebSocket.Handshake.handshake/3` with those per-upgrade opts.
- `deps/bandit/lib/bandit/websocket/handshake.ex:21-23` negotiates only when
  `Keyword.get(opts, :compress) && Keyword.get(websocket_opts, :compress, true)`.
  The second term is Bandit's global `websocket_options: [compress: ...]`, which
  defaults to true and which this repo does not set (grep of `config/` and
  `lib/` finds no `websocket_options`).
- `deps/bandit/lib/bandit/websocket/permessage_deflate.ex:24-30`
  (`negotiate/2`) builds the echoed `permessage-deflate` params;
  `deps/bandit/lib/bandit/websocket/connection.ex:270` deflates outgoing
  messages. Bandit is 1.10.3 (`deps/bandit/mix.exs:7`).

### Handshake evidence

- **Chrome offers** `permessage-deflate; client_max_window_bits` on every
  `/live` upgrade. Stage 1 recorded `deflate_offered: true` on every
  connection through the byte proxy, so I did not repeat the CDP
  `webSocketWillSendHandshakeRequest` capture; the proxy sees the raw request
  header, which is stronger evidence than CDP's parsed view.
- **Server echo, compress on** (dev server, raw HTTP/1.1 upgrade offering
  `Sec-WebSocket-Extensions: permessage-deflate; client_max_window_bits`):
  `HTTP/1.1 101` with `sec-websocket-extensions: permessage-deflate;client_max_window_bits=15`.
  The proxy logged `deflate_accepted: true` on the 101 of every Chrome
  connection in the compress-on run, and `false` on every one in the off run
  (`docs/perf/tab-switch-compress.data.json`).
- **Server echo, compress off** (same request, line removed): `HTTP/1.1 101`
  with no extension header.

### Tests

`apps/platform/test/platform_web/live_socket_compress_test.exs`:

1. unit: `PlatformWeb.Endpoint.__sockets__()` has `/live` and its `websocket`
   opts carry `compress: true`;
2. integration (feasible in ExUnit): Bandit started under `start_supervised!`
   on port 0 with `PlatformWeb.Endpoint` as the plug, a raw `:gen_tcp` upgrade
   to `/live/websocket`. With the extension offered the 101 must echo
   `permessage-deflate`; without an offer the 101 must carry no extension header.

Mutation proof. With `compress: true` deleted from the `/live` socket, both
the unit test and the offer-echo test go red (the no-offer test stays green,
as it should; it guards against forcing compression on):

```
  1) test the /live socket carries compress: true in its websocket opts (PlatformWeb.LiveSocketCompressTest)
     code:  assert Keyword.get(Keyword.fetch!(opts, :websocket), :compress) == true
     left:  nil
     right: true
  2) test handshake against a real Bandit listener echoes permessage-deflate when the client offers it (PlatformWeb.LiveSocketCompressTest)
     101 carried no Sec-WebSocket-Extensions header (compression declined)
     code: assert extension, "101 carried no Sec-WebSocket-Extensions header (compression declined)"
3 tests, 2 failures
```

Restored, `3 tests, 0 failures`. The change was restored before the commit.

### Re-measurement (local seeded, same fixture, same machine, same harness, N = 10)

Both columns were run back to back in one session on the same dev DB, one
server per setting (the "off" server had `compress: true` removed from the
working tree and was reverted afterwards). The stage 1 table above is a third,
older off sample. Tap and mount cells are median / p90. Wire is the
server-to-client TCP payload on `/live` from tap to ready, through the byte
proxy, as KiB.

| tab | raw join KiB | wire off KiB | wire on KiB | on / off | tap-to-interactive off ms | tap-to-interactive on ms | ready off ms | ready on ms | mount off ms | mount on ms |
|---|---|---|---|---|---|---|---|---|---|---|
| chat | 313.4 | 342.4 | 34.1 | 0.100 | 254 / 273 | 230 / 248 | 194 / 216 | 158 / 173 | 36 / 45 | 24 / 29 |
| voice | 65.3 | 76.5 | 11.5 | 0.151 | 54 / 82 | 56 / 64 | 44 / 70 | 50 / 53 | 16 / 26 | 19 / 20 |
| tasks (S1) | 190.5 | 203.0 | 24.9 | 0.123 | 116 / 133 | 115 / 132 | 93 / 107 | 87 / 92 | 15 / 28 | 15 / 20 |
| meetings | 71.2 | 84.0 | 12.3 | 0.146 | 61 / 78 | 60 / 62 | 55 / 68 | 55 / 58 | 15 / 23 | 15 / 16 |
| inbox | 57.5 | 68.7 | 10.4 | 0.152 | 51 / 61 | 53 / 59 | 48 / 53 | 50 / 53 | 15 / 19 | 16 / 19 |
| files | 78.3 | 89.5 | 12.1 | 0.135 | 73 / 104 | 60 / 72 | 66 / 97 | 53 / 57 | 25 / 39 | 16 / 17 |
| canvases | 79.2 | 90.3 | 12.2 | 0.135 | 105 / 140 | 58 / 63 | 98 / 132 | 51 / 54 | 39 / 58 | 15 / 18 |
| skills | 51.6 | 59.1 | 9.4 | 0.160 | 81 / 118 | 53 / 58 | 66 / 110 | 47 / 55 | 37 / 64 | 17 / 19 |
| org_memory | 65.1 | 76.7 | 11.5 | 0.149 | 58 / 69 | 53 / 62 | 52 / 67 | 46 / 55 | 15 / 16 | 17 / 20 |
| control | 60.4 | 71.6 | 11.4 | 0.159 | 71 / 76 | 66 / 143 | 66 / 70 | 56 / 138 | 20 / 20 | 22 / 80 |
| experiments | 56.4 | 67.6 | 10.5 | 0.156 | 58 / 71 | 56 / 58 | 53 / 68 | 48 / 53 | 15 / 17 | 17 / 20 |
| changelog | 51.2 | 62.3 | 9.2 | 0.148 | 47 / 56 | 55 / 84 | 43 / 49 | 52 / 73 | 14 / 16 | 15 / 31 |
| settings | 61.1 | 75.0 | 10.7 | 0.143 | 66 / 71 | 58 / 65 | 57 / 66 | 49 / 55 | 14 / 15 | 14 / 15 |

Reading it:

- **Wire bytes: measured, large.** Every tab sends 0.10 to 0.16 of the bytes
  it sent uncompressed. Chat's tap window falls from 342 to 34 KiB and tasks
  (S1) from 203 to 25 KiB. The stage 1 deflate estimate (chat 34.8, tasks 25.6
  KiB) landed within 2 percent of the measured on-the-wire figure (34.1, 24.9).
  The ratio is stable: on-the-wire bytes varied by under 10 bytes across taps.
- **Latency on loopback: INCONCLUSIVE.** Loopback transfer time is near zero,
  so removing bytes cannot show up much here, and the off run is noisy: the
  same view's server mount ranges 14 to 39 ms between tabs that do the same
  work (files, canvases, skills in the off run ran 25 to 37 ms against 15 to 17
  ms for the on run), and the machine's load average moved between 4 and 18
  during this stage. Chat's tap-to-interactive is 24 ms lower with
  compression (254 vs 230 median, 273 vs 248 p90), but stage 1's uncompressed
  figure was 233, so the off-vs-on gap sits inside the spread between two off
  samples. The data does not distinguish "compression speeds the tap up"
  from "no effect locally". The case for latency rests on a real network
  (bytes over a slow link), which this rig does not have.
  Two on-run cells (control p90 143, changelog p90 84) are single outliers
  from load, not compression effects: their medians match the off run.
- **Tasks S2 and phone viewports were not re-run.** S2 needs the fixture
  re-seeded with `--no-project-pref`; the `--tasks-scenario S2` flag alone
  re-ran the S1 board (join reply 195,065 B), so no S2 number is claimed.
  An earlier full on-run in this session, taken while the box was at load 17,
  failed from the second tab on (no 101 through the proxy, same symptom as the
  stage 1 phone S1 runs) and was discarded as a rig fault; it is run 0 of
  `on.json` in the raw data and is not used. The same server answered a clean
  re-run once the load fell. That the symptom also appeared with compression
  off in stage 1 says it is the rig under load, not deflate.

### Server cost of deflate

Measured on the dev node by tracing `Bandit.WebSocket.PerMessageDeflate.deflate/2`
(call and return, timestamped) while the harness ran 10 taps. The tracer itself
adds overhead, so these are upper bounds.

| payload | bytes in | deflate time per message |
|---|---|---|
| chat join reply | 320,900 | about 4.6 ms (21 to 23 samples per size, range 4.3 to 5.0, one 7.9 outlier) |
| tasks (S1) join reply | 195,065 | about 3.5 ms |
| a 59 KiB reply (inbox, voice) | 58,910 | about 1.1 ms |

LiveView mount (the view's own work, `[:phoenix, :live_view, :mount, :stop]`)
is unchanged: it is not part of the deflate call and is on the table above.
Deflate runs in the socket process after the reply is built and costs 1 to 5 ms
of that process's time per full-page reply; it is paid once per navigation. The cost of the small
diffs that follow was not measured. No memory
measurement was taken for the per-connection deflate context.

### Exp

| | after compression |
|---|---|
| exp wire bytes per tab | **pending deploy** |
| exp tap-to-interactive | **pending deploy** |

Exp numbers exist only once this is merged and deployed and an account Ryan
provided is available. The estimated-deflate column in the stage 1 table stands
as the forecast. Nothing here used a borrowed credential, wrote to prod, or ran
on hive.
