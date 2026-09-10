# Does `display: none` destroy a scroll offset? (task 01a084bf stage 5)

## Why this exists

Task 01a084bf's behavioural gate measured a reader parked mid-history in the
call rail's Chat tab being thrown to the bottom by a tab round trip:

    P1 Chat        scrollTop 354   max 614
    P2 People      scrollTop 0  scrollHeight 0  clientHeight 0
    P3 Transcript  scrollTop 0  scrollHeight 0  clientHeight 0
    P4 Chat        scrollTop 614  scrollHeight 1107  clientHeight 493

It attributed this to the browser: `[data-role="call-rail-chat-wrap"]` carries
`hidden`, the scroller computes `display: none`, and "the browser discards its
scroll offset ... and on return the list lands at the bottom".

That diagnosis had a remedy attached — stop the pane computing `display: none`,
either by taking it out of flow while keeping a layout box, or by saving and
restoring `scrollTop` from a new hook. Both are markup or new-owner changes to
a load-bearing pane. So the premise was worth checking first, and the gate's
own numbers already argue against it: a *discarded* offset lands at 0, the TOP.
614 is exactly `scrollHeight - clientHeight`. Only a write reaches that.

## What was measured

`probe.html` builds a scroll container inside a wrapper shaped like the real
one — `display: flex`, `height: 100%`, an inner `overflow-y-auto` scroller with
`overflow-anchor: none` — and carries Tailwind v4.1.12's preflight rule
verbatim:

    [hidden]:where(:not([hidden='until-found'])) { display: none !important; }

The `!important` matters and is why the probe is faithful. Without it the
wrapper's own `.flex` (equal specificity, later in the cascade) would win and
the `hidden` attribute would not hide anything at all. It was read out of the
`tailwind-macos-arm64` v4.1.12 binary the project pins in `config/config.exs`.

Then it parks the scroller at 354 and drives four round trips.

**Browser: Google Chrome 152.0.7977.83, macOS arm64, headless.**

    node ... --version                    -> Google Chrome 152.0.7977.83

    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
      --headless=new --disable-gpu --no-sandbox \
      --remote-debugging-port=9333 --user-data-dir=<tmp> about:blank &
    node cdp.mjs

## Result

`results/chrome-152-hidden-roundtrip.json`, verbatim:

| step                                            | scrollTop | scrollHeight | clientHeight |
| ----------------------------------------------- | --------- | ------------ | ------------ |
| 1 parked                                        | 354       | 1220         | 300          |
| 2 hidden                                        | 0         | 0            | 0            |
| 3 shown again                                   | **354**   | 1220         | 300          |
| 4 hidden, 5 rows appended                       | 0         | 0            | 0            |
| 5 shown after append                            | **354**   | 1525         | 300          |
| 6 hidden, `scrollTop = scrollHeight` attempted   | 0         | 0            | 0            |
| 7 shown after that write                        | **354**   | 1525         | 300          |
| 8 hidden 60 frames, shown (parked at 300)       | **300**   | 1525         | 300          |

**The browser retains the offset and hands it back, in all four shapes.** It
also discards a `scrollTop` write attempted while the element is box-less
(step 6 → 7), so the offset cannot be clobbered from JS during that window.

## What that means

`display: none` is not the destroyer, `hidden` needs no replacing, and neither
sketched remedy would have fixed anything. The destroyer is
`_onViewportResize` in `assets/js/hooks/scroll_to_bottom.js`: the
ResizeObserver delivers the 0x0 box, the old code *recorded* it into
`_lastClientWidth`, `_lastClientHeight` and `_lastScrollHeight`, and on the way
back the width path reconstructed the reader's pre-resize distance from those
zeroes — `0 - 354 - 0 = -354`, under `NEAR_BOTTOM_PX` — decided the reader had
been following the live edge, and snapped.

Seeded with the gate's own three numbers that arithmetic reproduces the gate's
trace exactly, 354 → 0 → 614. That reproduction, the fix and its mutation
controls are in `assets/test/scroll_to_bottom_hidden_pane_test.mjs`.

## Independent corroboration already in the tree

`assets/js/hooks/meeting_transcript.js` gates its own ResizeObserver on
`this.el.clientHeight > 0`, with a comment saying that on tab reveal a reader
who had scrolled up "keeps their place" because of "whatever scrollTop the
browser restores". Different author, sibling pane, same `hidden` attribute,
already shipping. The chat pane was the outlier. That precedent and the
measurement above are independent of each other.

## How to read the e2e re-run, including the way this fix could be insufficient

Nothing in this directory or in `assets/test/` proves a real reader keeps their
place. That is the e2e re-run's job, and its three possible outcomes are not
equally informative — record which one you get.

* **P4 scrollTop 354.** Done. The mechanism above was the whole of it.

* **P4 scrollTop 614 (the bottom) again.** The fix did not take. Something is
  still writing `scrollTop = scrollHeight`; `_onViewportResize` is the first
  suspect but not the only writer in the hook.

* **P4 scrollTop 0 (the TOP).** A *different*, second mechanism, and this one
  is predicted rather than observed — flagged here so it is not mistaken for
  the first. Clause 2 of the gate reported the held
  `[data-role="call-rail-chat-wrap"]` reference detached while the nested
  `#meeting-chat-panel-<uuid>` container stayed the same connected node. Those
  two cannot both be true of a plain removal — a detached node's descendants
  are detached with it — but they are both true of a morphdom RELOCATION,
  which LiveView's patcher does to keyed nodes and which
  `scroll_to_bottom.js`'s realign-guard note documents doing to this very
  scroller (`insertBefore` of an attached node detaches it first, and a
  detached scroller reads `scrollTop` 0 on re-insert, with no scroll event).
  If that is happening at the wrap level, the existing repair does not see it:
  `_connectRealignObserver` watches only `scrollEl.parentElement`'s child
  list, and a wrap several levels up is a mutation on a different parent.
  The fix would then be to widen that observer's vantage point, reusing the
  `_scrollObservedTop` memory that is already maintained for exactly this
  failure — not to change how the pane hides.

  This was deliberately NOT built speculatively. There is no measurement that
  a relocation occurs, the two candidate mechanisms both land the reader at
  the bottom today so the gate's trace cannot distinguish them, and building
  a repair for a defect that may not exist is how the last three passes over
  this hook undid each other.

## What would falsify this

A run of `probe.html` in which step 3 reports `scrollTop 0` rather than 354.
That is the whole load-bearing claim. It is browser- and version-specific:
these numbers are Chrome 152 only, and Firefox and WebKit are **not** measured
here. The e2e gate for this task drives Chrome over CDP, so the gate and this
measurement agree on the engine — but a reader porting this reasoning to
another engine has to re-run the probe there.

---

# Second round: the relocation IS measured, and it is the whole defect

The open question left above — "there is no measurement that a relocation
occurs" — is now answered. It occurs. `results/chrome-152-relocation.json` and
`results/chrome-152-app-roundtrip.json` are the two runs that settle it, and
`reloc.html` is the isolation rig.

## What was measured in the app

A `MutationObserver` on `document.body` across a real mouse click from Chat to
People recorded three childList records in ONE batch at t=15-20ms: a NEW
`[data-role="call-rail-chat-wrap"]` added to `[data-role="call-rail-pane"]`, the
`#meeting-chat-panel-<uuid>` REMOVED from `[data-pane="meeting-chat-panel"]`,
and the SAME node ADDED back. `isConnected` read true at all three: the subtree
was MOVED, so it never rests detached.

Node identity from the scroller upward: depths 0-4 the SAME nodes, depths 5 and
6 REPLACED, depth 7 (`call-rail-pane`) and above the same. **The mutation lands
four levels above `scrollEl.parentElement`**, which is the entire vantage point
the pre-fix `_connectRealignObserver` had. The round trip BACK to Chat produced
no relocation records at all: there is exactly one, on the way out.

## `display: none` is not involved, in either direction

`reloc.html` reproduces that three-record shape on a static page:

    hide then show, NO relocation      354 -> 354   retained   (positive control)
    hide AND relocate, then show       354 ->   0   lost
    relocate while fully VISIBLE       354 ->   0   lost       (the isolation)

The third line is the one that settles it: no `hidden`, no `display: none`,
nothing but the move, and the reader is still lost. This is consistent with the
first round's finding rather than a reversal of it — `display: none` really does
retain the offset, which is why the first round's own probe was right and its
mechanism claim was wrong anyway. The destroyer was never the hide.

## Why the repair has to be DEFERRED, not just widened

The remedy this README proposed above — widen the observer and reuse the
`_scrollObservedTop` memory — is necessary and **not sufficient**, and the
insufficient version fails silently.

A `scrollTop` write on a box-less element is DISCARDED (step 6/7 of
`chrome-152-hidden-roundtrip.json`, and re-measured in the app: at the People
tab the hidden scroller was written 696, read back 0 in the same expression, and
returned to Chat at 0). The tab patch relocates the scroller in the SAME batch
that takes the wrap to `display: none`, so the observer callback ALWAYS runs
box-less on this transition. A repair that writes there runs, changes nothing,
and looks like a fix. `_repairRealignedScroll` therefore holds the offset in
`_pendingRealignTop` and `_applyPendingRealign` pays it back from the two paths
that run with a box.

## The rig hazard that cost a run

`Page.navigate` served a CACHED `/assets/js/app.js`, so a build carrying the fix
measured P4 = 0 — indistinguishable from an unfixed build. `curl`-ing the served
file proves what the SERVER has, not what the PAGE loaded. Every run now sends
`Network.setCacheDisabled` and asserts the LOADED hook object carries the fix
(`liveSocket` hooks -> `ScrollToBottom._applyPendingRealign`) before trusting a
number.

## What would falsify this round

A run of `reloc.html` in which case C2 reports `scrollTop 354` — i.e. moving a
scroll container preserves its offset. Then the mechanism is something else and
the widened observer is repairing a defect it does not cause. Same engine caveat
as above: Chrome 152 only.
