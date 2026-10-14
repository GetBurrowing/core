"""Scroll-position stability while inline canvases lazy-mount (task 01a13884 stage 4).

    python3 chatscroll.py --cdp 192.0.2.200:9222 --base-url http://192.0.2.200:4020 \
        --space <canvas-heavy space id> --step 250 --settle 0.8

Opens /chat/<space>, waits for arrival, then scrolls UP in --step px steps
until the top of the loaded history (older batches load on the way). Each
step picks a reference message row visible just under the scroller's top
edge, reads its offset right after the scroll and again after --settle
seconds, and reports the difference as `drift`: anything that moved the
reader's lines AFTER they scrolled (a placeholder above the viewport turning
into a taller or shorter document, a frame scaling, a prepend). The stage-5
review bound is |drift| < 8 px.

Positive control, same run: every wrapper's height is read before the walk
(placeholders) and after it (documents). `would_jump_px` is that difference
for each canvas that mounted above the viewport: the drift each mount would
have caused with no reservation and no compensation. A walk where it is all
~0 cannot tell a fix from no fix.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, check_base_url, common_args, out_dir  # noqa: E402

WALK_JS = """
(async (step, settleMs, maxSteps) => {
  const sleep = (ms) => new Promise(r => setTimeout(r, ms));
  const sc = document.getElementById('chat-message-scroller');
  const wrappers = () => [...document.querySelectorAll('[id^="inline-canvas-"]')];
  const rows = () => [...document.querySelectorAll('#message-list > [id^="messages-"]')];
  const before = {};
  for (const w of wrappers()) before[w.id] = {h: w.getBoundingClientRect().height, mounted: w.dataset.mounted};
  const steps = [];
  let idle = 0;
  for (let i = 0; i < maxSteps && idle < 3; i++) {
    const top = sc.getBoundingClientRect().top;
    const ref = rows().find(r => r.getBoundingClientRect().top >= top + 40);
    if (!ref) break;
    const mountedBefore = wrappers().filter(w => w.dataset.mounted === 'true').length;
    const rowsBefore = rows().length;
    const prevTop = sc.scrollTop;
    sc.scrollTop = Math.max(0, sc.scrollTop - step);
    const moved = prevTop - sc.scrollTop;
    const t1 = ref.getBoundingClientRect().top;
    await sleep(settleMs);
    const t2 = ref.isConnected ? ref.getBoundingClientRect().top : null;
    const mountedAfter = wrappers().filter(w => w.dataset.mounted === 'true').length;
    steps.push({i, ref: ref.id, scrolled: moved, drift: t2 === null ? null : Math.round((t2 - t1) * 10) / 10,
                mounts: mountedAfter - mountedBefore, rows_added: rows().length - rowsBefore, scrollTop: sc.scrollTop});
    idle = (moved === 0 && rows().length === rowsBefore) ? idle + 1 : 0;
  }
  const after = {};
  for (const w of wrappers()) after[w.id] = {h: w.getBoundingClientRect().height, mounted: w.dataset.mounted};
  const swaps = Object.keys(before).filter(k => after[k] && before[k].mounted === 'false' && after[k].mounted === 'true')
    .map(k => ({id: k, placeholder_h: Math.round(before[k].h), mounted_h: Math.round(after[k].h),
                would_jump_px: Math.round(after[k].h - before[k].h)}));
  return {steps, swaps, placeholders_left: wrappers().filter(w => w.dataset.mounted === 'false').length,
          iframes: document.querySelectorAll('iframe').length};
})(%d, %d, %d)
"""


def report(n, r, od):
    drifts = [s["drift"] for s in r["steps"] if s["drift"] is not None]
    mount_steps = [s for s in r["steps"] if s["mounts"] > 0]
    print(f"pass {n} out: {od}")
    print(f"steps={len(r['steps'])} mount_steps={len(mount_steps)} "
          f"older_batches={sum(1 for s in r['steps'] if s['rows_added'] > 0)} "
          f"placeholders_left={r['placeholders_left']} iframes={r['iframes']}")
    print(f"max |drift| all steps = {max((abs(d) for d in drifts), default=0)} px; "
          f"on mount steps = {max((abs(s['drift']) for s in mount_steps if s['drift'] is not None), default=0)} px")
    jumps = [abs(s["would_jump_px"]) for s in r["swaps"]]
    print(f"positive control: {len(r['swaps'])} swaps, would-jump px max={max(jumps, default=0)} "
          f"median={sorted(jumps)[len(jumps) // 2] if jumps else 0}")
    for s in r["steps"]:
        if s["rows_added"] or (s["drift"] and abs(s["drift"]) >= 1):
            print(f"  step {s['i']:3} drift={s['drift']:>7} mounts={s['mounts']} rows_added={s['rows_added']} scrollTop={s['scrollTop']}")


def main():
    p = common_args(__doc__)
    p.add_argument("--space", required=True, help="id of the canvas-heavy space")
    p.add_argument("--step", type=int, default=250)
    p.add_argument("--settle", type=float, default=0.8)
    p.add_argument("--max-steps", type=int, default=120)
    p.add_argument(
        "--passes",
        type=int,
        default=1,
        help="walk N times, reloading in the same browser context, so pass 2+ "
        "starts from the heights pass 1 recorded in browser storage",
    )
    args = p.parse_args()
    base = check_base_url(args.base_url)
    od = out_dir(args)

    c = CDP(args.cdp)
    c.open_page(args.width, args.height)
    try:
        c.login(base, args.login_as)
        results = []
        for n in range(args.passes):
            c.goto(f"{base}/chat/{args.space}", 6)
            if not c.live_ok():
                raise SystemExit("liveSocket is not connected")
            r = c.js(WALK_JS % (args.step, int(args.settle * 1000), args.max_steps))
            results.append(r)
            report(n + 1, r, od)
        with open(os.path.join(od, "chatscroll.json"), "w") as f:
            json.dump(results, f, indent=2)
    finally:
        c.close()


if __name__ == "__main__":
    main()
