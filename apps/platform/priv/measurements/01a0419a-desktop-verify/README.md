# Desktop verification — task 01a0419a v3 stage 5

Every shipped measurement for the jump-to-latest control was taken at 390x844.
Stage 1 made the overlay unconditional, so the empirical criteria are retaken
at **1440x900**, both themes. The mobile record in `assets/css/app.css` is
KEPT — it still describes what ships there. The numbers here are appended to
it as a v3 addendum.

## Running it

```bash
# named node so the probe can drive real server-side broadcasts by RPC
cd apps/platform
PLATFORM_DEV_DATABASE=platform_dev_01a0419a_s3 PORT=4021 \
  elixir --sname s5node --cookie s5probecookie -S mix phx.server

cd priv/measurements/01a0419a-desktop-verify
SPORT=4021 SPACE_ID=<uuid> VW=1440 VH=900 THEME=light node probe.mjs   # gate, centring, hover, layout shift
SPORT=4021 SPACE_ID=<uuid> THEME=light node probe2.mjs                 # occlusion + line occlusion sweep
SPORT=4021 SPACE_ID=<uuid> THEME=light node probe3.mjs                 # reachability, 3 geometries
SPORT=4021 SPACE_ID=<uuid> THEME=light node probe4.mjs                 # contrast, pixel-sampled
SPORT=4021 node stylesheet_scan.mjs                                    # served-stylesheet enumeration
```

Every probe opens its own `Target.createBrowserContext`. CDP port 9222 is
shared with sibling agents on this box and one Chrome profile is one identity,
so an isolated context is what stops this run re-logging-in someone else's tab.
Nothing here ever `pkill`s by pattern; the dev server is stopped by the PID
holding port 4021.

## THE FIXTURE HAD A DEFECT, AND IT IS WORTH KNOWING

`chat_messages.id` is `Platform.Types.UUIDv7` and `Chat.list_messages/2`
orders by `inserted_at` but paginates with `where: m.id < ^before_id`. The
seed used in stage 3 generated ids with `Ecto.UUID.bingenerate()` — **UUIDv4,
random** — so id order was uncorrelated with time order and the cursor
dead-ended after ~51 rows. The scroller then topped out around 2,351px, which
at a 730px pane is a maximum distance of 1,621px: **below `DEEP_HISTORY_PX`
(1800), so the deep band was unreachable and the pill never rendered at all.**

That failure presents as "the layout is broken", not as "the fixture is too
short", which is why it cost a while to find. The reseed generates the ids,
**sorts them**, and assigns them in `inserted_at` order, so the two orders
agree by construction; the seed asserts `id_order_matches_time_order` before
returning. It is committed here as `reseed.exs` — run it with
`mix run priv/measurements/01a0419a-desktop-verify/reseed.exs` against the dev
database and check the returned map says `id_order_matches_time_order: true`. `loadHistory` now also uses real `Input.dispatchMouseEvent`
mouseWheel gestures rather than a synthetic `scroll` Event, and VOIDS loudly
if the deep band is still unreachable rather than measuring a short tree.

## TWO PROBE BUGS THAT PRODUCED CLEAN-LOOKING WRONG ANSWERS

Recorded because both passed and neither was true.

1. **The layout-shift selector fell through to `hidden md:block`** — an
   unrelated element ~700px up the page, which of course never moves. It
   reported `delta: 0`. A zero that measures nothing is indistinguishable
   from a zero that measures the right thing. The probe now pins
   `.compose-input-area` by name and refuses to report a number if it is
   absent.

2. **Reachability conflated "off-viewport" with "blocked by the pill".**
   `elementFromPoint` returns `null` outside the viewport, and the first
   enumeration swept in ~380 per-message hover-toolbar buttons plus targets
   at `y >= 900`, giving 314 "unreachable" results of which exactly zero were
   the pill's doing. The predicate now separates `offViewport`, `blockedByPill`
   and `reachable`, and the enumeration excludes invisible and off-screen
   elements with the exclusion counts reported.

## What is NOT claimed

The spec's void-check — assert `.chat-jump-anchor` computes
`position: absolute` — is **wrong and is not used**. That element computes
`relative` under the new layout and `static` under the old one; `absolute`
belongs to `.chat-jump-anchor-row`. Asserting it would void every run,
including a correct one. The gate here checks the four values that actually
distinguish the two layouts and refutes `display: contents` by name.
