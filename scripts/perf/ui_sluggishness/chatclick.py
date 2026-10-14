"""Chat space-switch profile (task 01a13884 stage 1).

    python3 chatclick.py --cdp 192.0.2.200:9222 --base-url http://192.0.2.200:4020 \
        --space <heavy space id> --from <light space id> --switches 3

Signs in through /dev/login in a private browser context, opens /chat/<from>,
then clicks the sidebar link to /chat/<space> and back, --switches times.
The sidebar links by space id (`/chat/<uuid>`), so pass ids; the seed prints
`heavy_space_id` and `light_space_id`.
Each switch INTO --space is one row: settle time, DOM nodes, ws-in, max frame,
long tasks, top-5 contributors, plus iframe and inline-canvas counts.
If the sidebar has no link to the space, the row says so instead of
navigating some other way.
"""

import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, CpuProfile, attribute, check_base_url, common_args, fmt_top, frame_sizes, kb, out_dir  # noqa: E402

SWITCH_JS = """
new Promise(res=>{
  const href=%s;
  const a=[...document.querySelectorAll('a[href]')].find(x=>x.getAttribute('href')===href && (x.offsetParent||x.getClientRects().length));
  if(!a){res({ok:false,ms:-1});return}
  const t0=performance.now();a.click();
  const chk=()=>{
    if(location.pathname===href && !document.querySelector('.phx-loading,.phx-click-loading'))
      setTimeout(()=>res({ok:true,ms:Math.round(performance.now()-t0)}),250);
    else if(performance.now()-t0>15000) res({ok:false,ms:-1});
    else setTimeout(chk,20)
  };chk()
})
"""


def perf_metrics(c):
    m = c.send("Performance.getMetrics").get("metrics", [])
    return {x["name"]: x["value"] for x in m}


def switch(c, href, drain, cpu=None):
    c.events.clear()
    c.take_longtasks()
    before = perf_metrics(c)
    if cpu:
        cpu.start()
    t0 = time.time()
    r = c.js(SWITCH_JS % json.dumps(href)) or {"ok": False, "ms": -1}
    c.drain(drain)
    prof = cpu.stop() if cpu else None
    after = perf_metrics(c)
    frames = c.ws_frames()
    sizes = frame_sizes(frames)
    lt = c.take_longtasks()
    return {
        "to": href,
        "ok": r["ok"],
        "settle_ms": r["ms"],
        "started_at": t0,
        "ended_at": time.time(),
        "nodes": c.nodes(),
        "iframes": c.js("document.querySelectorAll('iframe').length"),
        "messages": c.js("document.querySelectorAll('[id^=messages-],[data-message-id]').length"),
        "ws_in_bytes": sum(sizes),
        "max_frame_bytes": max(sizes or [0]),
        "frames": sizes,
        "longtask_ms": sum(lt),
        "longtasks": lt,
        "top": attribute(frames, c.cid_names())[:10],
        "inline_canvases": c.js("document.querySelectorAll('[id^=canvas-doc-]').length"),
        "placeholders": c.js("document.querySelectorAll('[data-role=inline-canvas-placeholder]').length"),
        # Renderer-wide main-thread split (Performance domain, seconds -> ms).
        "main_thread_ms": {
            k: round((after.get(k, 0) - before.get(k, 0)) * 1000)
            for k in ("TaskDuration", "ScriptDuration", "LayoutDuration", "RecalcStyleDuration")
        },
        "cpu": prof,
    }


def main():
    p = common_args(__doc__)
    p.add_argument("--space", required=True, help="id (as the sidebar links it) of the heavy space to switch into")
    p.add_argument("--from", dest="from_space", required=True, help="id of the light space to switch from")
    p.add_argument("--switches", type=int, default=3)
    p.add_argument("--drain", type=float, default=2.0)
    p.add_argument("--cpu-profile", action="store_true", help="sample JS self-time per switch (Profiler domain)")
    args = p.parse_args()
    base = check_base_url(args.base_url)
    od = out_dir(args)

    c = CDP(args.cdp)
    c.open_page(args.width, args.height)
    rows = []
    try:
        c.login(base, args.login_as)
        c.goto(f"{base}/chat/{args.from_space}", 8)
        print(f"out: {od}  at={c.where()} live={c.live_ok()} nodes={c.nodes()}")
        if not c.live_ok():
            raise SystemExit("liveSocket is not connected")
        cpu = CpuProfile(c) if args.cpu_profile else None
        print(f"{'switch':8} {'ok':>5} {'settle':>7} {'nodes':>6} {'iframes':>7} {'ws_in_KB':>9} {'max_KB':>8} {'lt_ms':>6}  top")
        for i in range(args.switches):
            r = switch(c, f"/chat/{args.space}", args.drain, cpu)
            r["row"] = f"switch {i}"
            rows.append(r)
            print(
                f"{r['row']:8} {str(r['ok']):>5} {r['settle_ms']:>7} {r['nodes']:>6} {r['iframes']:>7} "
                f"{kb(r['ws_in_bytes']):>9} {kb(r['max_frame_bytes']):>8} {r['longtask_ms']:>6}  {fmt_top(r['top'])}"
            )
            print(f"         longtasks={r['longtasks']} canvases={r['inline_canvases']} "
                  f"placeholders={r['placeholders']} main_thread_ms={r['main_thread_ms']}")
            if r["cpu"]:
                print(f"         cpu busy={r['cpu']['busy_ms']}ms top={r['cpu']['top_self_ms'][:6]}")
            back = switch(c, f"/chat/{args.from_space}", args.drain)
            back["row"] = f"back {i}"
            rows.append(back)
    finally:
        with open(os.path.join(od, "chatclick.json"), "w") as f:
            json.dump(rows, f, indent=2)
        c.close()


if __name__ == "__main__":
    main()
