#!/usr/bin/env python3
"""Fragment baseline for task 01a03fb9 stage 1.

Splits the negatives_102 false positives by fragment vs complete utterance,
using CHEAP LEXICAL SIGNALS ONLY -- no model call per row. See README section
"Fragment definition" for the rationale and the hand-check.

Usage:
    python3 priv/intent_eval/analysis/fragment_split.py <run.json> [--json <out>]

`--json` writes the counts keyed by corpus row `id`. It deliberately carries
NO transcript text: the utterances are real people talking, and the slices
already in this repo are the one place that content lives.
"""
import json
import re
import sys

# The four fragments the ticket named, as their synthetic stand-ins in
# negatives_102 (pre-public scrub: same rows, same fragment shape).
TICKET_FOUR = ["hardware in the", "Globex wants", "check again whether or not",
               "Okay, I'm waiting for the chime."]

TERMINAL = ("."  , "?", "!", "…")


def is_fragment(text):
    """Cheap, deterministic fragment test. Returns (bool, reason).

    F1  no terminal punctuation at the end   -> the STT emits . ? ! when it
        believes a sentence completed; a VAD cut on silence mid-thought does
        not get one.
    F2  begins lowercase                     -> the segment continues a prior
        one, i.e. the head of the utterance was emitted as a separate segment.
    """
    t = text.strip().strip('"“”')
    if not t:
        return True, "empty"
    reasons = []
    if not t.endswith(TERMINAL):
        reasons.append("F1:no-terminal-punct")
    if re.match(r"^[a-z]", t):
        reasons.append("F2:starts-lowercase")
    return (bool(reasons), "+".join(reasons) if reasons else "complete")


def fired(row):
    """A false positive: no error class, and an intent other than off_topic."""
    return row["error_class"] is None and row["predicted"] != "off_topic"


def main(path):
    doc = json.load(open(path))
    neg = [r for r in doc["rows"] if r["slice"] == "negatives_102"]
    assert len(neg) == 102, f"expected 102 negatives, got {len(neg)}"

    fps = [r for r in neg if fired(r)]

    all_frag = [r for r in neg if is_fragment(r["text"])[0]]
    fp_frag = [r for r in fps if is_fragment(r["text"])[0]]
    fp_comp = [r for r in fps if not is_fragment(r["text"])[0]]

    print(f"run                     : {path.split('/')[-1]}")
    print(f"negatives_102 rows      : {len(neg)}")
    print(f"FALSE POSITIVES (fired) : {len(fps)}")
    print(f"correct declines        : {len(neg) - len(fps)}")
    print()
    print(f"fragments in whole slice: {len(all_frag)} of {len(neg)}"
          f"  ({100*len(all_frag)/len(neg):.1f}%)")
    print()
    print("FALSE POSITIVES SPLIT")
    print(f"  fragment          : {len(fp_frag)} of {len(fps)}")
    print(f"  complete utterance: {len(fp_comp)} of {len(fps)}")
    print()
    print("  -- fragment FPs (reachable by a fragment gate) --")
    for r in fp_frag:
        print(f"     {r['predicted']:<18} [{is_fragment(r['text'])[1]}] {r['text']!r}")
    print()
    print("  -- complete-utterance FPs (NOT reachable by a fragment gate) --")
    for r in fp_comp:
        print(f"     {r['predicted']:<18} {r['text']!r}")
    print()

    ticket = TICKET_FOUR
    print("THE FOUR FRAGMENTS NAMED IN THE TICKET")
    for t in ticket:
        m = [r for r in neg if r["text"] == t]
        if not m:
            print(f"     ABSENT FROM CORPUS: {t!r}")
            continue
        r = m[0]
        print(f"     predicted={r['predicted']:<12} fired={fired(r)!s:<5}"
              f" is_fragment={is_fragment(t)[0]!s:<5} {t!r}")


def emit(path, out):
    doc = json.load(open(path))
    neg = [r for r in doc["rows"] if r["slice"] == "negatives_102"]
    fps = [r for r in neg if fired(r)]
    fp_frag = [r for r in fps if is_fragment(r["text"])[0]]
    fp_comp = [r for r in fps if not is_fragment(r["text"])[0]]
    payload = {
        "task": "01a03fb9-46b4-7fef-8654-628a2874b5f0",
        "stage": 1,
        "config_name": doc["manifest"]["config"]["name"],
        "config_sha256": doc["manifest"]["config"]["sha256"],
        "prompt_rendered_sha256": doc["manifest"]["prompt"]["rendered_sha256"],
        "harness_git_sha": doc["manifest"]["harness_git_sha"],
        "negatives_slice_sha256": next(
            s["sha256"] for s in doc["manifest"]["slices"]
            if s["name"] == "negatives_102"
        ),
        "mode": doc["manifest"]["mode"],
        "note": "row ids only; no transcript text by design",
        "fragment_definition": {
            "F1": "text does not end in . ? ! or …",
            "F2": "text begins with a lowercase letter",
            "rule": "fragment if F1 or F2",
            "signals": "lexical only - no model call, no silence duration, "
                       "no speaker change (neither is recorded in this corpus)",
        },
        "counts": {
            "negatives_total": len(neg),
            "false_positives": len(fps),
            "correct_declines": len(neg) - len(fps),
            "fragments_in_slice": sum(1 for r in neg if is_fragment(r["text"])[0]),
            "false_positives_fragment": len(fp_frag),
            "false_positives_complete": len(fp_comp),
        },
        "false_positive_ids": {
            "fragment": sorted(r["id"] for r in fp_frag),
            "complete": sorted(r["id"] for r in fp_comp),
        },
        "ticket_four_fragments": {
            r["id"]: {"predicted": r["predicted"], "fired": fired(r)}
            for t in TICKET_FOUR
            for r in neg if r["text"] == t
        },
    }
    json.dump(payload, open(out, "w"), indent=2, sort_keys=True)
    open(out, "a").write("\n")
    print(f"wrote {out}")


if __name__ == "__main__":
    main(sys.argv[1])
    if "--json" in sys.argv:
        emit(sys.argv[1], sys.argv[sys.argv.index("--json") + 1])
