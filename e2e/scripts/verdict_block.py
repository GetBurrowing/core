#!/usr/bin/env python3
"""Turn one `meeting_layout_geometry.spec.ts` run into a MACHINE-READABLE
verdict block.

WHY A PARSER AND NOT JUST `playwright test`. A reviewer pasting a green tick
into an evidence canvas has proved nothing: a bare PASS is indistinguishable
from an assertion that could not fail. This prints the MEASURED NUMBERS AND THE
TOLERANCE on every line, PASS lines included, so the reader can see what was
compared against what.

The PASS/FAIL on each line is recomputed HERE from the measured numbers rather
than copied from playwright's tick, and the two are cross-checked: a
disagreement prints VERDICT-MISMATCH rather than quietly picking one. That is
what catches a spec whose assertion drifts away from the number it logs.

Exit: 0 all PASS, 1 any FAIL, 4 no verdict data at all (crash/timeout).
"""

import argparse
import json
import re
import sys

TESTS = [
    ("ring parentage", "RING_PARENTAGE"),
    ("controls placement", "CONTROLS_PLACEMENT"),
    ("grid fill", "GRID_FILL"),
    ("candidate card", "CARD_ORDER"),
]

NUM = r"-?\d+(?:\.\d+)?"


def find_all(pattern, text):
    return list(re.finditer(pattern, text))


def overflows(blob):
    """`{"top":0,"right":0,...}` -> the worst edge overflow as a float."""
    try:
        d = json.loads(blob)
    except Exception:
        return None
    return max(float(d.get(k, 0)) for k in ("top", "right", "bottom", "left"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    ap.add_argument("--surface", required=True)
    ap.add_argument("--viewport", required=True)
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--asset-sha", default="?")
    ap.add_argument("--asset-bytes", default="?")
    ap.add_argument("--server-id", default="UNKNOWN")
    ap.add_argument("--run-status", default="?")
    a = ap.parse_args()

    raw = open(a.raw, encoding="utf-8", errors="replace").read()
    tag = "%s/%s" % (a.surface, a.viewport)

    # ── playwright's own per-test outcome, for the cross-check ──────────────
    outcome = {}
    for line in raw.splitlines():
        if "%s @ %s" % (a.surface, a.viewport) not in line:
            continue
        for needle, name in TESTS:
            if needle not in line:
                continue
            if "✘" in line or "✗" in line:
                outcome[name] = "FAIL"
            elif "✓" in line or "✔" in line:
                outcome[name] = "PASS"
            elif line.lstrip().startswith("-") or "skipped" in line.lower():
                outcome[name] = "SKIP"

    lines = []          # (assertion, text, verdict)
    def emit(name, body, verdict):
        lines.append((name, body, verdict))

    # ── PART D — THE PRELUDE, SHOWN TO HAVE RUN ────────────────────────────
    #
    # The quickmeet renders NO rail until `meeting_join` is clicked, and below
    # `lg` none is on screen until `[data-role="quickmeet-rail-toggle"]` is
    # pressed. A capture taken before both is a false "feature missing" and has
    # already cost review cycles, so the prelude is encoded in the runner's
    # surface path — not left to the caller — and its execution is PRINTED.
    width = a.viewport.split("x")[0]
    m = re.search(r"\[prelude\] %s/%s (.*)" % (re.escape(a.surface), width), raw)
    emit("prelude", m.group(1) if m else
         "NOT OBSERVED — the surface path did not report its prelude; treat any "
         "'feature missing' reading below as unproven", "INFO" if m else "FAIL")

    # ── ASSERTION 1 — RING PARENTAGE ───────────────────────────────────────
    rows = find_all(
        r"\[ring-parentage\] %s row=(\S+) state=(\S+) ring=(\{[^}]*\}) face=(\{[^}]*\}) "
        r"faceOutsideRing=(\{[^}]*\}) worst=(%s) tol=(%s)" % (re.escape(tag), NUM, NUM),
        raw,
    )
    for m in rows:
        row, state, ringr, facer, of, worst, tol = m.groups()
        ok = float(worst) <= float(tol)
        emit(
            "ring.parentage",
            "row=%s state=%s ring=%s face=%s faceOutsideRing=%s worst=%s tol=%s"
            % (row, state, ringr, facer, of, worst, tol),
            "PASS" if ok else "FAIL",
        )
    glyphs = find_all(
        r"\[ring-glyph\] %s row=(\S+) state=(\S+) glyph=(\{[^}]*\}) "
        r"faceBRQuadrant=(\{[^}]*\}) overlap=(%s)x(%s)" % (re.escape(tag), NUM, NUM),
        raw,
    )
    for m in glyphs:
        row, state, gr, quad, ow, oh = m.groups()
        ok = float(ow) > 0 and float(oh) > 0
        emit(
            "ring.glyph",
            "row=%s state=%s glyph=%s faceBottomRightQuadrant=%s overlap=%sx%s tol=>0x>0"
            % (row, state, gr, quad, ow, oh),
            "PASS" if ok else "FAIL",
        )
    summary = re.search(
        r"\[ring-parentage\] %s rows=(\d+) statesExercised=(\[[^\]]*\])" % re.escape(tag), raw
    )
    if summary:
        n, states = summary.groups()
        # A KNOWN, NAMED GAP — carried into the verdict block rather than left
        # to read as a silent pass. `:computing` / `:typing` / `:failed` have
        # in-memory-only producers and the dev container's serving BEAM runs
        # with no distribution, so nothing outside the node can drive them.
        # Every seeded agent renders `:idle` and the glyph-overlap branch is
        # therefore NEVER EXERCISED by this rig.
        gap = "" if states != '["idle"]' else \
            "  GAP: only :idle was exercised; the glyph-overlap branch did not run on this rig"
        emit(
            "ring.states",
            "rows=%s statesExercised=%s glyphBranchExercised=%s%s"
            % (n, states, "no" if states == '["idle"]' else "yes", gap),
            "INFO",
        )

    # ── ASSERTION 2 — CONTROLS PLACEMENT ───────────────────────────────────
    m = re.search(
        r"\[controls\] %s allControlsRects=(\[[^\]]*\])" % re.escape(tag), raw)
    if m:
        emit("controls.duplicates",
             "allControlsRects=%s  (the zero-rect copy is the hidden lg-only duplicate; "
             "visibleRect() picked the laid-out one)" % m.group(1), "INFO")
    m = re.search(
        r"\[controls-below\] %s controls\.top=(%s) stage\.bottom=(%s) delta=([+-]?%s) tol=(%s)"
        % (re.escape(tag), NUM, NUM, NUM, NUM), raw)
    if m:
        top, bot, delta, tol = m.groups()
        ok = float(delta) >= -float(tol)
        emit("controls.below",
             "controls.top=%s stage.bottom=%s delta=%s tol=%s" % (top, bot, delta, tol),
             "PASS" if ok else "FAIL")
    m = re.search(
        r"\[controls-centred\] %s controls\.cx=(%s) stage\.cx=(%s) delta=(%s) tol=(%s)"
        % (re.escape(tag), NUM, NUM, NUM, NUM), raw)
    if m:
        ccx, scx, delta, tol = m.groups()
        ok = float(delta) <= float(tol)
        emit("controls.centred",
             "controls.cx=%s stage.cx=%s delta=%s tol=%s" % (ccx, scx, delta, tol),
             "PASS" if ok else "FAIL")
    for m in find_all(
        r"\[controls-clip\] %s btn=(\S+) rect=(\{[^}]*\}) panel=(\{[^}]*\}) "
        r"viewportOverflow=(\{[^}]*\}) panelOverflow=(\{[^}]*\})" % re.escape(tag), raw):
        btn, r, panel, vo, po = m.groups()
        worst_v, worst_p = overflows(vo), overflows(po)
        ok = (worst_v == 0) and (worst_p == 0)
        emit("controls.clip",
             "btn=%s rect=%s panel=%s viewportOverflow=%s panelOverflow=%s tol=0"
             % (btn, r, panel, vo, po),
             "PASS" if ok else "FAIL")

    # A FAIL at (a) aborts the controls test before the clipping sub-assertion
    # ever runs. Saying so beats a verdict block where `controls.clip` is simply
    # absent and reads as "not applicable".
    if int(width) < 1024 and not any(n == "controls.clip" for n, _, _ in lines):
        emit("controls.clip",
             "NOT REACHED — the controls test aborted at an earlier sub-assertion, so no "
             "per-button viewport/panel overflow was measured at this viewport. This is "
             "unmeasured, NOT passing.", "INFO")

    # ── ASSERTION 3 — GRID FILL ────────────────────────────────────────────
    m = re.search(
        r"\[grid-fill\] %s stage=(\{[^}]*\}) grid=(\{[^}]*\}) stagePadding=(\{[^}]*\}) "
        r"tolX=(%s)\(=padLeft\+padRight\) tolY=(%s)\(=padTop\+padBottom\) "
        r"widthDeficit=(%s) heightDeficit=(%s) heightAxisAsserted=(\w+)"
        % (re.escape(tag), NUM, NUM, NUM, NUM), raw)
    if m:
        stage, grid, pad, tolx, toly, dx, dy, hax = m.groups()
        emit("grid.fill.x",
             "stage=%s grid=%s stagePadding=%s widthDeficit=%s tolX=%s(DERIVED=padLeft+padRight)"
             % (stage, grid, pad, dx, tolx),
             "PASS" if float(dx) <= float(tolx) else "FAIL")
        if hax == "true":
            emit("grid.fill.y",
                 "stage=%s grid=%s heightDeficit=%s tolY=%s(DERIVED=padTop+padBottom)"
                 % (stage, grid, dy, toly),
                 "PASS" if float(dy) <= float(toly) else "FAIL")
        else:
            emit("grid.fill.y",
                 "heightDeficit=%s tolY=%s NOT ASSERTED on this surface — the quickmeet stage is a "
                 "scroll column that also parents the share slot, self-view and dock, so its height "
                 "is not the grid's to fill. Number printed so the scope decision is on the record."
                 % (dy, toly),
                 "INFO")
    m = re.search(
        r"\[grid-cells\] %s cells=(\d+) union=(\{[^}]*\}) grid=(\{[^}]*\}) "
        r"widthDeficit=(%s) heightDeficit=(%s) tolX=(%s) tolY=(%s)"
        % (re.escape(tag), NUM, NUM, NUM, NUM), raw)
    if m:
        n, union, grid, dx, dy, tolx, toly = m.groups()
        tol = max(float(tolx), float(toly))
        ok = float(dx) <= tol and float(dy) <= tol
        emit("grid.cells.union",
             "cells=%s union=%s grid=%s widthDeficit=%s heightDeficit=%s tol=%s"
             % (n, union, grid, dx, dy, tol),
             "PASS" if ok else "FAIL")
    elif a.surface == "quickmeet":
        emit("grid.cells.union",
             "cells=0 NOT ASSERTED — the quickmeet grid is phx-update=\"ignore\" and "
             "meeting_client.js emits no [data-gallery-cell] marker. An empty node list here is a "
             "JS-ownership fact, not a layout failure.", "INFO")

    # ── ASSERTION 4 — CANDIDATE CARD READING ORDER ─────────────────────────
    m = re.search(
        r"\[card-order\] %s domOrder\(quote,assignment\)=(\S+) quote=(\{[^}]*\}) "
        r"assignment=(\{[^}]*\})" % re.escape(tag), raw)
    if m:
        order, q, asg = m.groups()
        emit("card.domorder",
             "domOrder(quote,assignment)=%s expected=before quote=%s assignment=%s"
             % (order, q, asg),
             "PASS" if order == "before" else "FAIL")
        qb = float(re.search(r"b:(%s)" % NUM, q).group(1))
        at = float(re.search(r"t:(%s)" % NUM, asg).group(1))
        emit("card.painted",
             "assignment.top=%s quote.bottom=%s delta=%+.1f tol=0" % (at, qb, at - qb),
             "PASS" if at >= qb else "FAIL")
    else:
        probe = re.search(r"\[card-order\] %s probed=(\S+) cards=\[([^\]]*)\]"
                          % re.escape(tag), raw)
        detail = ("probed=%s cards=[%s]" % probe.groups()) if probe else "no card data logged"
        emit("card.domorder",
             "%s  SKIPPED: no laid-out card renders BOTH meeting-candidate-quote and "
             "meeting-candidate-assignment. Sibling task 01a05b14 stage 4 lands the populated "
             "card's quote line; until then this is a stated precondition, not a green tick "
             "over nothing." % detail,
             "SKIP")

    # ── AN ASSERTION THAT FAILS BEFORE IT LOGS ─────────────────────────────
    #
    # The ancestry half of ring parentage fires BEFORE any rect is printed, so a
    # ring moved out of the avatar wrapper produces a red test and NO
    # measurement line at all. Left alone the verdict block would simply be
    # missing a row — which reads as "not applicable", the exact ambiguity this
    # whole gate exists to remove. Synthesise an explicit FAIL row carrying the
    # spec's own error text instead.
    prefix = {"RING_PARENTAGE": "ring", "CONTROLS_PLACEMENT": "controls",
              "GRID_FILL": "grid", "CARD_ORDER": "card"}
    errs = re.findall(r"^\s*(?:Error|\d+\)).*$", raw, re.M)
    for group, pw in outcome.items():
        if pw != "FAIL":
            continue
        pfx = prefix[group]
        if any(n.split(".")[0] == pfx and v == "FAIL" for n, _, v in lines):
            continue
        detail = next((e.strip() for e in errs if e.strip().startswith("Error")),
                      "no error text captured")
        lines.append((
            "%s.unmeasured" % pfx,
            "FAILED BEFORE LOGGING ANY MEASUREMENT — the assertion aborted before a rect was "
            "printed, so there are no numbers for this row. Spec error: %s" % detail[:400],
            "FAIL"))

    if not lines:
        print("no verdict data — the spec produced no measurement lines for %s" % tag)
        return 4

    fails = [l for l in lines if l[2] == "FAIL"]
    skips = [l for l in lines if l[2] == "SKIP"]

    w = max(len(n) for n, _, _ in lines)
    print("=== MEETING LAYOUT VERDICT ==================================================")
    print("surface=%s viewport=%s base_url=%s" % (a.surface, a.viewport, a.base_url))
    print("rig: assets/js/app.js sha256[0:16]=%s bytes=%s"
          % (a.asset_sha, a.asset_bytes))
    print("     MEASURED GAP: the asset hash does NOT identify the server. This task's")
    print("     container on :4046 and the sibling task's on :4040 serve a BYTE-IDENTICAL")
    print("     app.js, so a hash match proves nothing about which branch was rendered.")
    print("served-by: %s" % a.server_id)
    if "WRONG SERVER" in a.server_id:
        print("*** STOP — every measurement below describes a DIFFERENT BRANCH. Not a layout result.")
    print("-----------------------------------------------------------------------------")
    for name, body, verdict in lines:
        print("%-6s %-*s %s" % (verdict, w, name, body))
    print("-----------------------------------------------------------------------------")
    print("TOTAL assertions=%d pass=%d fail=%d skip=%d info=%d"
          % (len(lines),
             len([l for l in lines if l[2] == "PASS"]),
             len(fails), len(skips),
             len([l for l in lines if l[2] == "INFO"])))

    # CROSS-CHECK. The verdict above is computed from the logged numbers; this
    # is playwright's independent tick. A disagreement means the spec asserts
    # something other than the number it prints — reported, never reconciled.
    derived = {}
    for name, _, verdict in lines:
        group = {"ring": "RING_PARENTAGE", "controls": "CONTROLS_PLACEMENT",
                 "grid": "GRID_FILL", "card": "CARD_ORDER"}.get(name.split(".")[0])
        if group is None:
            continue
        if verdict == "FAIL":
            derived[group] = "FAIL"
        elif verdict == "SKIP":
            derived.setdefault(group, "SKIP")
        elif verdict == "PASS":
            derived.setdefault(group, "PASS")
    for group, pw in sorted(outcome.items()):
        mine = derived.get(group, "?")
        if mine != pw:
            print("VERDICT-MISMATCH %s: numbers say %s, playwright says %s — the spec is "
                  "asserting something other than the number it logs." % (group, mine, pw))
        else:
            print("crosscheck %s: numbers=%s playwright=%s AGREE" % (group, mine, pw))
    print("=============================================================================")

    if fails:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
