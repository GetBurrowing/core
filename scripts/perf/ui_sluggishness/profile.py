"""Per-click / per-close payload profile of /tasks (task 01a13884 stage 1).

    python3 profile.py --cdp 192.0.2.200:9222 --base-url http://192.0.2.200:4020 --clicks 3

Signs in through /dev/login in a private browser context, loads /tasks, then
for each of --clicks cards (picked from different kanban columns):

  click i  select the card, drain the CDP socket for --drain seconds
  close i  click the detail panel's close button, drain again

Close frames are drained and reported on their OWN row. The pre-port script
slept after the close without reading the socket, so the close's frames were
read during the next click and counted as that click's.

Each row: total ws-in, max frame, frame count, summed long tasks, and the
top-5 contributors by serialized size (per component cid, mapped through
[data-phx-component], and per root key). Wall-clock start/end per row are
recorded in profile.json so server-side :telemetry timings can be joined.
"""

import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, CpuProfile, attribute, heaviest_path, check_base_url, common_args, fmt_top, frame_sizes, kb, out_dir  # noqa: E402

PICK_CARDS = """
(()=>{
  const vis = e => !!(e.offsetParent || e.getClientRects().length);
  const cols = [...document.querySelectorAll('[data-column]')];
  const out = [];
  for (const col of cols) {
    const cards = [...col.querySelectorAll('[phx-click=select_task][phx-value-id]')].filter(vis);
    if (cards.length) out.push({column: col.getAttribute('data-column'), id: cards[0].getAttribute('phx-value-id')});
  }
  if (!out.length) {
    for (const el of [...document.querySelectorAll('[phx-click=select_task][phx-value-id]')].filter(vis).slice(0, 8))
      out.push({column: '?', id: el.getAttribute('phx-value-id')});
  }
  return out;
})()
"""


def click_js(selector):
    return (
        "(()=>{const vis=e=>!!(e.offsetParent||e.getClientRects().length);"
        f"const el=[...document.querySelectorAll({json.dumps(selector)})].find(vis);"
        "if(!el)return false;el.click();return true})()"
    )


def measure(c, label, action_js, drain, cpu=None, external_cmd=None):
    c.events.clear()
    c.take_longtasks()
    names_before = c.cid_names()
    if cpu:
        cpu.start()
    t0 = time.time()
    if external_cmd:
        ok = subprocess.run(external_cmd, shell=True, capture_output=True, text=True).returncode == 0
    else:
        ok = c.js(action_js)
    c.drain(drain)
    t1 = time.time()
    cpu_summary = cpu.stop() if cpu else None
    frames = c.ws_frames()
    sent = c.ws_frames("sent")
    sizes = frame_sizes(frames)
    names = {**names_before, **c.cid_names()}
    top = attribute(frames, names)
    lt = c.take_longtasks()
    return {
        "row": label,
        "action_ok": ok,
        "at": c.where(),
        "started_at": t0,
        "ended_at": t1,
        "ws_in_bytes": sum(sizes),
        "ws_out_bytes": sum(frame_sizes(sent)),
        "max_frame_bytes": max(sizes or [0]),
        "frames": sizes,
        "longtask_ms": sum(lt),
        "longtasks": lt,
        "nodes": c.nodes(),
        "top": top[:10],
        "heaviest": heaviest_path(frames, _key_of(top[0][0])) if top else [],
        "cpu": cpu_summary,
        "_raw_frames": frames,
    }


def _key_of(label):
    # "cid 3 (tasks-board)" -> "c/3"; "root 5" -> "5"
    parts = label.split()
    return f"c/{parts[1]}" if parts[0] == "cid" else parts[1]


def show(r):
    print(
        f"{r['row']:10} {str(r['action_ok']):>5} {kb(r['ws_in_bytes']):>9} {kb(r['max_frame_bytes']):>9} "
        f"{len(r['frames']):>6} {r['longtask_ms']:>6} {r['nodes']:>7}  {r['at'][:40]:40}  {fmt_top(r['top'])}"
    )
    for lvl in r.get("heaviest") or []:
        kids = ", ".join(f"{k}={kb(v)}KB" for k, v in lvl["children"])
        print(f"{'':12}heaviest {lvl['path']} ({lvl['child_count']} keys): {kids}")
    if r.get("cpu"):
        cp = r["cpu"]
        tops = "; ".join(f"{k}={v}ms" for k, v in cp["top_self_ms"][:6])
        print(f"{'':12}js busy={cp['busy_ms']}ms  {tops}")


def main():
    p = common_args(__doc__)
    p.add_argument("--clicks", type=int, default=3)
    p.add_argument("--drain", type=float, default=2.0)
    p.add_argument("--settle", type=float, default=10.0)
    p.add_argument("--cpu-profile", action="store_true", help="sample JS self-time per row (Profiler domain)")
    p.add_argument("--dump-frames", action="store_true", help="write each row's raw received frames to frames-<row>.json")
    p.add_argument(
        "--external-cmd",
        default=None,
        help="shell command run --externals times with the page on /tasks (e.g. an rpc that updates one task); "
        "its frames are reported as 'external i' rows",
    )
    p.add_argument("--externals", type=int, default=1)
    args = p.parse_args()
    base = check_base_url(args.base_url)
    od = out_dir(args)

    c = CDP(args.cdp)
    c.open_page(args.width, args.height)
    rows = []
    try:
        c.login(base, args.login_as)
        c.events.clear()
        t0 = time.time()
        c.send("Page.navigate", {"url": f"{base}/tasks"})
        c.drain(args.settle)
        frames = c.ws_frames()
        sizes = frame_sizes(frames)
        lt = c.take_longtasks()
        join = {
            "row": "join",
            "at": c.where(),
            "started_at": t0,
            "ended_at": time.time(),
            "ws_in_bytes": sum(sizes),
            "max_frame_bytes": max(sizes or [0]),
            "frames": sizes,
            "longtask_ms": sum(lt),
            "longtasks": lt,
            "nodes": c.nodes(),
            "live": c.live_ok(),
            "select_task_targets": c.js("document.querySelectorAll('[phx-click=select_task]').length"),
            "kanban_cards": c.js("document.querySelectorAll('[data-column] [phx-click=select_task]').length"),
            "top": attribute(frames, c.cid_names())[:10],
        }
        rows.append(join)
        print(f"out: {od}")
        print(
            f"join: at={join['at']} live={join['live']} nodes={join['nodes']} "
            f"select_task_targets={join['select_task_targets']} kanban_cards={join['kanban_cards']} "
            f"ws_in={kb(join['ws_in_bytes'])}KB max_frame={kb(join['max_frame_bytes'])}KB "
            f"longtasks={join['longtask_ms']}ms  {fmt_top(join['top'])}"
        )
        if not join["live"]:
            raise SystemExit("liveSocket is not connected; every click would be a false negative")

        cpu = CpuProfile(c) if args.cpu_profile else None
        picks = c.js(PICK_CARDS) or []
        print(f"{'row':10} {'ok':>5} {'ws_in_KB':>9} {'max_KB':>9} {'frames':>6} {'lt_ms':>6} {'nodes':>7}  {'at':40}  top contributors")
        for i in range(args.clicks):
            pick = picks[i % len(picks)]
            sel = f"[phx-click=select_task][phx-value-id=\"{pick['id']}\"]"
            r = measure(c, f"click {i}", click_js(sel), args.drain, cpu)
            r["column"] = pick["column"]
            r["task_id"] = pick["id"]
            rows.append(r)
            show(r)
            r = measure(c, f"close {i}", click_js("[phx-click=detail_close]"), args.drain, cpu)
            rows.append(r)
            show(r)

        for i in range(args.externals if args.external_cmd else 0):
            r = measure(c, f"external {i}", None, args.drain + 1.0, cpu, args.external_cmd)
            rows.append(r)
            show(r)

        m = c.send("Performance.getMetrics")["metrics"]
        mm = {x["name"]: x["value"] for x in m}
        metrics = {k: round(mm[k]) for k in ["Nodes", "JSEventListeners", "JSHeapUsedSize", "LayoutCount", "RecalcStyleCount"] if k in mm}
        rows.append({"row": "metrics", **metrics})
        print(metrics)
    finally:
        for r in rows:
            raw = r.pop("_raw_frames", None)
            if args.dump_frames and raw is not None:
                with open(os.path.join(od, f"frames-{r['row'].replace(' ', '-')}.json"), "w") as f:
                    json.dump(raw, f)
        with open(os.path.join(od, "profile.json"), "w") as f:
            json.dump(rows, f, indent=2)
        c.close()


if __name__ == "__main__":
    main()
