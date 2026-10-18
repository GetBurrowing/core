# open_question pilot dataset and programs (task 01a0e8b5)

Program files are saved Imp programs (`Imp.save!/2` artefacts) that an
`imp_program` arm of the `meetings.open_question_classifier` experiment
surface may name by basename. The only one checked in is
`baseline_v0.json`, the UNOPTIMISED baseline (`OpenQuestionPilot.Program.new/0`:
no demos, no optimisation). It is what the tests use to exercise the
imp_program arm's MECHANICS: assignment, stickiness, org scoping and the
privacy floor. It is NOT "B". Stage 4 found no admissible optimised
program (see below), so no `program_b.json` exists. The other `.json`
files here (`arm_a.json`, `results.json`) are not programs, and the
surface refuses them because `Imp.read!/1` cannot load them.

`dataset.jsonl` is the labelled set the open_question pilot scores both arms
on: the control prompt (`meetings.intent_classify.v1`) and the Imp program
`excerpt, participants -> is_question: bool, addressee`. Loaded by
`Platform.Meetings.OpenQuestionPilot.Dataset`.

## Fixture rule (binding; from tasks 01a0a12e and 01a0e58f)

- Every row is **synthesised**, or is one of the two real specimens the
  ticket allows: "Write my strategy" and "Is this a demo? No, this is the…".
  Those two carry `"origin": "real_specimen"`.
- **No real transcript line.** Nothing was read from any meeting, transcript,
  candidate or other DB row. Nothing was copied from
  `priv/intent_eval/slices/*`, candidates, prelabels or cassettes.
- Names are wholly invented. Shapes were filed from the 2026-09-14
  one-to-one; no row quotes it.
- Every row was read against one question: would this be damaging if the
  person it is about read it? Rows about named people are about work
  logistics only, except `privacy` rows, whose candid register is the point:
  they must never become an artefact.

## Provenance

- `corpus-*` rows (53) are copies of
  `test/support/scribe_misfire_corpus.ex` at `0d3b6196`. Their
  `provenance` names the source list and index, e.g.
  `copied_from: test/support/scribe_misfire_corpus.ex@0d3b6196 negatives[0] (misfire intent action_items)`.
  `open_question_pilot/dataset_drift_test.exs` fails if a copied row stops
  matching its source.
- Labels for copied rows: only the three `open_question` positives are
  `is_question: true`. Every misfire negative, cause row, non-question
  positive and privacy row is `false`, as the corpus files them.
- Every other row (47) is synthesised for this task.

## Schema

```
id, text, participants: [name], is_question: bool, addressee: name | "none",
shape, privacy: bool, origin: "synthesised" | "real_specimen", provenance, split
```

A non-question's `addressee` is always `"none"`. The ticket's privacy row
"Priya to deliver list of demands to Marcus by end of week" is
`corpus-privacy-01`: `privacy: true`, `is_question: false`, participants
Priya, Dana, Marcus.

## Split

Deterministic, stratified by `{shape, is_question, privacy}`, seed
`01a0e8b5-open-question-split-v1`, targets train 40 / val 25 / test 35.
`corpus-privacy-01` (the Priya line) is pinned to **test**. The algorithm is
in the `Dataset` moduledoc. The stored `split` column is recomputed and
compared by `dataset_test.exs`, which also checks this table.

| split | n | is_question true | is_question false | privacy | privacy and question |
|-------|---|------------------|-------------------|---------|----------------------|
| train | 40 | 14 | 26 | 5 | 2 |
| val | 25 | 9 | 16 | 3 | 1 |
| test | 35 | 12 | 23 | 4 | 1 |
| all | 100 | 35 | 65 | 12 | 4 |

## Measured run (task 01a0e8b5 stage 4)

One run of `mix platform.open_question_pilot.run`, at branch sha `d05f408b`,
on test-host, 2026-09-29. Wall time 263 s. The full record is `results.json`, and
`cassettes/test_prompt.jsonl` replays arm A's TEST calls with no network
(`results_replay_test.exs` checks that the numbers reproduce exactly).

**Arm A was re-recorded on 2026-10-18** (task 01a14dce stage 1), so the arm A
numbers in `results.json` and its cassette are no longer the ones in the table
below; see "Arm A re-recorded" at the end. The optimiser, selection and arm B
records are still this run's.

**Provider.** The configured classifier llama-server, model `classifier`
(`/props`: `/models/qwen-3-1.7b/Qwen3-1.7B-Q4_K_M.gguf`, n_ctx 8192, 4 slots,
build b9765-73618f27a). It served both the task model and GEPA's reflection
model, at temperature 0.0, max_tokens 1024, thinking off. The run reached it
as `http://host.containers.internal:8085/v1`: that is the same llama-server
process as `192.0.2.10:8085` (host network), but the rootless podman
network refuses the LAN address (`econnrefused`), so the podman host alias
was the only route. No other provider was used.

**Rig.** The stage names `localhost/core-test:1.19.5-otp-28-slim`, which
cannot compile erlexec (no make or g++). The run used the same base image
with `build-essential` added and nothing else, in a podman container on
test-host, from a clone of the branch on the test-host mirror, on `--network dev`, in
MIX_ENV=test against a scratch database. An earlier attempt at `3cdb49b7`
was stopped during baseline A, before GEPA started: its sandboxed Repo
connection expired after 120 s, which `d05f408b` fixes. That attempt
produced no result and was not a selection among runs. GEPA ran exactly
once.

| | A: prompt (control) | B: Imp program |
|---|---|---|
| TEST n | 35 (12 questions, 23 not, 4 privacy) | not scored: **inadmissible** |
| precision | 1.00 (3/3), 95% CI 0.44 to 1.00 | n/a |
| recall | 0.25 (3/12), 95% CI 0.09 to 0.53 | n/a |
| errors (parse, empty, model, budget) | 0, 0, 0, 0 | n/a |
| privacy (i): privacy rows routable as open_question or action_items | **4 of 4** | n/a |
| privacy (ii): artefacts not refused by gather_context | **2 of 4** as measured; **0 of 4** after the stage-5 floor fix (replay) | n/a |
| latency per chunk, p50 / p95 | 419 ms / 564 ms | n/a |
| tokens (TEST) | 81,353 (79,384 prompt) | n/a |
| cost | $0.00 (self-hosted) | $0.00 |

**Optimiser.** GEPA (`:gepa_v0_1_4_merge`), seed 20260929, max_metric_calls
300. It stopped on its own budget: `stop_reason` is
`{:stopper, [{:max_metric_calls, 302, 300}]}`, with 302 metric calls, 5 full
evaluations and 22 reflection calls. The task model made 304 calls against
a hard cap of 400, and the reflection model 22 against a cap of 40, so
neither hard cap was reached. The best validation score was 0.76, against
0.72 for the baseline program.

**Selection: B is INADMISSIBLE.** Five accepted candidates were checked,
best validation score first, over the 8 privacy rows of train and val. The
constraint is zero rows predicted to be a question. gepa-3 (val 0.76) had 3
violations, gepa-4 (0.76) 3, the baseline program (0.72) 2, gepa-2 (0.72) 3
and gepa-1 (0.68) 3. None was clean, so no `program_b.json` is written and
arm B was not run on TEST. Selection took 40 model calls.

**Spend.** 401 model calls in total: 35 for baseline A, 304 for the
optimiser's task model, 22 for reflection and 40 for selection. That is
439,462 tokens counted, excluding selection, whose tokens the meter records
but `results.json` does not total. Marginal cost $0.00.

### Recommendation: REJECT (for now)

- **B cannot be adopted.** No optimised or baseline Imp program kept the
  candid-register rows off the question path. Privacy is a hard constraint
  here, not a weight, so a better validation score does not buy admission.
  Every candidate called at least 2 of the 8 candid rows a question.
- **The control broke the privacy floor on this corpus, and that is now
  fixed.** Arm A routed all 4 TEST privacy rows as `action_items`. At
  measurement, the `gather_context/2` floor refused only 2 of them (the
  Priya line and the salary-figures line). It let through `privacy-q-04`
  ("Has anyone told Anouk the outcome of her promotion case?") and
  `privacy-s-01` ("Caspian asked to move to part-time for family
  reasons"). Ticket 01a0eb31 records that production finding, which is
  independent of Imp.

  **Stage 5 closed it.** `Platform.Meetings.IntentPrivacy` gained two
  classes, `:personnel_outcome` and `:personal_circumstances`. They only
  add refusals: no prompt, threshold or routing gate was touched, and
  scribe_misfire_rate is unchanged at 25. Re-scoring in REPLAY (`mix
  platform.open_question_pilot.rescore`: no model calls, cassette
  byte-identical, sha256 `fe008fd9…`) gives artefact level **0 of 4** for
  arm A. Output level (i) is still 4 of 4, because that is the classifier
  routing, which is out of scope. All 41 genuine positives still pass the
  floor. 39 of 41 produce their artefact before and after the fix; the
  other 2 are refused by the older near-miss check, identically on both
  sides.

  One candid shape is still not reached: a job-search question,
  "Is Isolde still interviewing with other companies?" (`privacy-q-02`,
  in TRAIN).
- **A's recall is low.** It found 3 of 12 genuine questions on TEST
  (precision 3/3). The six-way prompt sends most questions to `off_topic`,
  `brief_worthy` or `action_items`. That is the gap B was meant to close,
  and it is still open.
- **Needs more data before a second attempt.** Any retry should come with a
  privacy-aware program design (for example, a candid-register field the
  program must answer first), a larger privacy slice, and a reflection
  model larger than 1.7B.

### Caveats

- The corpus is synthetic: 100 rows, 53 of them copied from the scribe
  misfire corpus. It is NOT a production measurement.
- llama-server at temperature 0 is not deterministic across calls:
  `priv/intent_eval/README.md` records `negatives_102` reading 94 and then
  96 three minutes apart. The cassette pins what this run saw; a live
  re-run can differ by a row or two.
- n is small. TEST has 12 questions and 4 privacy rows, and the Wilson
  95% intervals above are wide: recall 0.09 to 0.53.
- The reflection model was the 1.7B classifier itself. It produced 22
  reflections, and none of them failed to parse (0 failed proposals). The
  best candidate improved validation from 0.72 to 0.76, 1 row of 25. Whether
  a 1.7B reflector is adequate is not established by this run; its
  instructions did not learn the privacy constraint.

## Arm A re-recorded (task 01a14dce stage 1, 2026-10-18)

`prompt_a.txt` changed by one line: an exemplar that quoted a real utterance
naming a real person became an invented line of the same shape. A cassette
key covers the whole system prompt, so every recorded answer became
unreachable. The old answers were NOT re-keyed, which would have claimed the
model answered a prompt it was never shown. Arm A was asked again instead:
`Runner.rerecord_arm_a!/3`, 35 live calls (one per TEST row), on the same
llama-server model file and build as the original run
(`Qwen3-1.7B-Q4_K_M.gguf`, `b9765-73618f27a`), reached as `localhost:8085`
from a host-network container. The `rerecorded` entry in `results.json`
records the run; its `sha` is the pre-rebase commit of the branch.

To separate model drift since 2026-09-29 from the text change, the OLD prompt
was also run once today, the same way, from a scratch branch. That run was
not committed.

| arm A, TEST n=35 | 2026-09-29 (recorded) | old prompt, today | new prompt, today (committed) |
|---|---|---|---|
| precision | 1.00 (3/3) | 1.00 (2/2) | 1.00 (2/2) |
| recall | 0.25 (3/12) | 0.17 (2/12) | 0.17 (2/12) |
| errors (parse, empty, model, budget) | 0, 0, 0, 0 | 0, 0, 0, 0 | 0, 0, 0, 0 |
| privacy (i): rows routable | 4 of 4 | 4 of 4 | 3 of 4 |
| privacy (ii): artefacts not refused | 0 of 4 (stage-5 replay) | 0 of 4 | **1 of 4** |

The recall drop is the same with the old prompt, so it is drift, not the
text change. The two runs today differ on ONE row: `privacy-q-04` was
`action_items` and refused with the old prompt, and is `decision_recorded`
and NOT refused with the new one. One row is inside the 1-2 row
run-to-run variation recorded under Caveats, so this does not show the
text change caused it. What it does show is that the `gather_context/2`
floor does not refuse this personnel-outcome row when the classifier routes
it to `decision_recorded`. That is a finding for the privacy floor, which is
out of this task's scope; it is recorded here and in the task's completion.
