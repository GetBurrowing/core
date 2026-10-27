# Tab-switch first frame: before and after (task 01a17bf4)

What the smaller chat first frame bought, per tab, on the stage-1 harness.
**These numbers are local seeded, shaped link, not prod.**

- **Change measured.** Chat's default space entry mounts the newest 10
  messages (`initial_message_count: 10`) and backfills the rest of the
  50-message window after connect; the per-message edited-count N+1 is batched.
  Nothing was deferred to `assign_async`: stage 3 measured no side-state
  segment over 3 ms (`deferred_side_state` stays `[]`).
- **Builds.** before = `409b4d1a6` (harness and spans only, N = 50). after =
  `a5a3adcb6` (the task branch).
- **Rig.** Fixture `apps/platform/priv/scripts/seed_tab_switch_fixture.exs`
  (user `tabswitch`, busy channel `tab-switch-busy`, 2,000 messages), dev
  server with Logger `:info`, the byte proxy shaped 9 Mbps down / 1.5 Mbps up /
  85 ms RTT (proxy shaper primary, as `tab-switch-baseline.md` Stage 3),
  permessage-deflate on, 10 measured taps per tab after one warm-up. Chat
  starts from `/inbox`; every other tab from the busy channel.
- **Load average** (1 min, at the start of each run): before 2.34, after 2.41.
  That is within 2x, so the full before-run was not repeated. Chat was re-run
  back to back on both builds anyway: before build 342 ms at 1280x800 (load
  3.04) against 343 in the original before-run; branch 294 ms (load 3.95)
  against 292. The before-run had no 390x844 chat run, so that before cell
  comes from the before build in the same session (load 3.42).
- **Raw data.** `docs/perf/tab-switch-first-frame.data.json`, runs `before`,
  `after`, `before-390x844-chat`, `after-390x844-chat`,
  `before-rerun-1280x800-chat`, `after-rerun-1280x800-chat`, and the
  `stage4_after_run` block.

## Per tab

Median of 10 taps unless the column says p90. **mount µs** is the arriving
LiveView's `mount` (telemetry native units); for chat the message window
loads in `handle_params`, which is in the attribution table below.
**first-frame KiB** is the join reply frame alone on the wire (frame headers
plus compressed payload). **tap** is tap-to-interactive.

<!-- first-frame-table:start -->
| tab | viewport | mount µs (before / after) | first-frame KiB (before / after) | tap median ms (before / after) | tap p90 ms (before / after) |
|---|---|---|---|---|---|
| chat | 1280x800 | 24801 / 24776 | 31.9 / 24.9 | 343 / 292 | 360 / 304 |
| chat | 390x844 | 25336 / 24348 | 31.9 / 24.9 | 381 / 298 | 392 / 308 |
| voice | 1280x800 | 15203 / 14960 | 10.8 / 10.7 | 158 / 157 | 162 / 168 |
| tasks | 1280x800 | 13615 / 13025 | 24.3 / 24.4 | 229 / 230 | 256 / 232 |
| meetings | 1280x800 | 11157 / 11683 | 11.5 / 11.5 | 155 / 161 | 161 / 163 |
| inbox | 1280x800 | 10852 / 11984 | 9.6 / 9.6 | 146 / 149 | 156 / 152 |
| files | 1280x800 | 14084 / 14219 | 11.3 / 11.3 | 166 / 161 | 174 / 166 |
| canvases | 1280x800 | 14343 / 14420 | 11.4 / 11.4 | 163 / 168 | 171 / 171 |
| skills | 1280x800 | 12836 / 13868 | 8.7 / 8.6 | 143 / 146 | 155 / 149 |
| org_memory | 1280x800 | 12850 / 10414 | 10.6 / 10.6 | 152 / 139 | 156 / 148 |
| control | 1280x800 | 16922 / 13365 | 10.6 / 10.6 | 166 / 150 | 170 / 153 |
| experiments | 1280x800 | 11472 / 12146 | 10.1 / 10.1 | 155 / 156 | 161 / 166 |
| changelog | 1280x800 | 11644 / 12146 | 8.5 / 8.4 | 146 / 150 | 151 / 153 |
| settings | 1280x800 | 11541 / 11727 | 10.2 / 10.2 | 151 / 151 | 153 / 155 |
<!-- first-frame-table:end -->

Reading it:

- **Chat** first frame 31.9 to 24.9 KiB (-22 percent), tap 343 to 292 ms
  (-51) at 1280x800 and 381 to 298 ms (-83) at 390x844, p90 down by the same.
- **Chat mount µs is flat** (24801 to 24776): mount was never where the
  message window ran. The saving is in `handle_params` (33.9 to 22.3 ms) and,
  mostly, on the client.
- **No other tab moved** beyond noise: every non-chat median is within 10 ms
  of its before value (largest rise meetings +6 ms; control and org_memory
  fell 16 and 13 ms, which is noise, as nothing changed there).

## Chat attribution (proxy 4G, compress on, ms, median of 10, 1280x800)

Stage-1 format: server = mount + handle_params from the node's telemetry;
client = CDP `TaskDuration` from just before the tap to ready; RTT = 85 (the
join round trip); transfer = tap-window wire KiB over 9 Mbps; sum = those
four; gap = tap minus sum.

<!-- chat-attribution:start -->
| run | tap | server | client main thread | RTT | transfer (wire KiB) | sum | gap |
|---|---|---|---|---|---|---|---|
| chat before | 343 | 59 | 146 | 85 | 30 (32.7) | 320 | +23 |
| chat after | 292 | 47 | 90 | 85 | 32 (34.7) | 253 | +39 |
<!-- chat-attribution:end -->

- **Client main thread is the win**: 146 to 90 ms (-56). Server -12 ms
  (arrival queries 250 to 208).
- **Tap-window wire went up** 32.7 to 34.7 KiB: the 40-row backfill diff now
  lands inside the tap window, after the smaller join reply. Transfer is +2 ms.
- **The gap grew** (+23 to +39 ms). Not isolated; the candidates are the
  backfill diff arriving and patching before the keystroke probe lands, and the
  keystroke round trip. It stays labelled unexplained.

## Keep-alive recommendation (recommend only, nothing implemented)

Stage-1 rule: sticky is warranted if chat (or any tab) is still above 288 ms
(2 x the 144 ms small-tab median) after this work, or if the remaining cost is
the 85 ms round-trip floor that only a kept view removes.

**Both apply, so keep chat alive next, and only chat.**

- **288 ms rule: fires, narrowly.** Chat after is 292 ms (re-run 294, p90 304)
  at 1280x800 and 298 ms at 390x844, 4 to 10 ms above 288. That margin is
  inside run-to-run spread, so this leg alone would be a coin toss. Every
  other tab is under it: tasks (S1) 230, the small tabs 139 to 168 (median
  152).
- **Round-trip floor: the stronger leg.** Of chat's 292 ms, 85 is the join
  round trip and 32 is transfer, both of which a fresh mount pays every tap
  and a kept view does not. Chat's excess over the small-tab median is now 140
  ms (292 - 152), of which server is 32 (47 vs about 15) and client 40 (90 vs
  about 50). The first-frame lever that cut 51 ms is spent: the message window
  is already 10 rows, and stage 3 found no side-state segment worth deferring.
  The 85 ms floor is now 29 percent of chat's tap (and 56 percent of a small
  tab's), and only a mounted-and-kept view removes it.
- **What it would not fix, and what it costs.** It helps returns to chat
  only, not first visits; how often users return to chat is not measured here.
  It holds one LiveView process per kept tab per session. Tasks S2 (board size)
  is a different lever.
