"""Page-load audit: DOM nodes, ws-in on join, long tasks (task 01a13884 stage 1).

    python3 audit.py --cdp 192.0.2.200:9222 --base-url http://192.0.2.200:4020 /tasks /chat

Signs in through /dev/login in a private browser context, then loads each
path and drains the CDP socket for --settle seconds. Prints one row per page
and writes audit.json under the output dir.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdp import CDP, attribute, check_base_url, common_args, fmt_top, frame_sizes, kb, out_dir  # noqa: E402


def main():
    p = common_args(__doc__)
    p.add_argument("--settle", type=float, default=8.0)
    p.add_argument("paths", nargs="+")
    args = p.parse_args()
    base = check_base_url(args.base_url)
    od = out_dir(args)

    c = CDP(args.cdp)
    c.open_page(args.width, args.height)
    rows = []
    try:
        c.login(base, args.login_as)
        print(f"out: {od}")
        print(f"{'page':34} {'nodes':>7} {'ws_in_KB':>9} {'max_frame_KB':>12} {'longtask_ms':>11} {'max_lt':>6} {'live':>5}  top")
        for path in args.paths:
            c.events.clear()
            c.send("Page.navigate", {"url": base + path})
            c.drain(args.settle)
            frames = c.ws_frames()
            sizes = frame_sizes(frames)
            lt = c.take_longtasks()
            names = c.cid_names()
            top = attribute(frames, names)
            row = {
                "page": path,
                "landed": c.where(),
                "nodes": c.nodes(),
                "ws_in_bytes": sum(sizes),
                "max_frame_bytes": max(sizes or [0]),
                "frames": len(sizes),
                "longtask_ms": sum(lt),
                "longtasks": lt,
                "live": c.live_ok(),
                "top": top[:10],
            }
            rows.append(row)
            print(
                f"{path[:34]:34} {row['nodes']:>7} {kb(row['ws_in_bytes']):>9} {kb(row['max_frame_bytes']):>12} "
                f"{row['longtask_ms']:>11} {max(lt or [0]):>6} {str(row['live']):>5}  {fmt_top(top)}"
            )
    finally:
        with open(os.path.join(od, "audit.json"), "w") as f:
            json.dump(rows, f, indent=2)
        c.close()


if __name__ == "__main__":
    main()
