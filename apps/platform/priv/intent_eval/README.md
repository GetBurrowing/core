# Intent-classification evaluation set and offline harness

Task `01a03fbb-3ef1-73b1-9fe9-eb1d37a5484a`. The labelled set landed in stage 3;
the harness that scores a prompt config against it landed in stage 4; the
**deliberately broken configs that prove the harness can tell a good config from
a bad one** landed in stage 5.

```
mix platform.intent_eval.run --config off_topic_default            # replay, no network
mix platform.intent_eval.run --config off_topic_default --record   # calls the live endpoint
mix platform.intent_eval.run --config off_topic_default --slice negatives_102
```

Run `mix` from `apps/platform`. There is no root `mix.exs`.

## Endpoint dependency — read this before you plan work here

The classifier under test is a ~2B model served by llama-server, model name
`classifier`, at **`http://192.0.2.10:8085/v1` — address it by IP.**

**The hostname `test-host` does not resolve from every box, including the build-host box
these stages were executed on.** Only the LAN IP is usable there, which is what
every config here carries. An agent asked to pick up the `off_topic` tuning work
found no DNS, no HTTP and no SSH to `test-host`, and correctly declined rather than
ship blind; stage 4 lost the same twenty minutes to the same hostname. The IP
form works; the name form is a coin flip. Use the IP.

That host-boundness is a standing tax and **this harness does not inherit it**:

* **Without test-host access you can run `--replay` against any committed cassette,
  run the entire test suite, and reproduce every published number.**
* **Without test-host access you CANNOT produce fresh numbers for a config that has
  no cassette.** There is no offline substitute for a model call that was never
  made, and the harness will not pretend otherwise.

A `--replay` run that misses a key **fails loudly**, naming the missing keys and
the count. It never falls through to a live call — that would put the
host-boundness straight back — and it never scores the missing row as an error,
which would corrupt the numbers with a harness bug wearing a model result's
clothes.

## Layout

```
manifest.json              slice inventory + sha256s (stage 3)
slices/*.jsonl             the labelled rows: 102 negatives, 60 control, 12 probe,
                           48 unaddressed meeting speech (stage 4, NOT in the default run)
configs/<name>.json        committed DATA describing an arm
prompts/<name>.txt         inline prompt bodies referenced by configs
exemplars/<name>.jsonl     correction rows for the {{correction_exemplars}} slot (stage 4)
cassettes/<config>.jsonl   recorded provider responses, keyed by prompt+chunk
runs/                      run output; gitignored except the runs named below
README.md                  this file
```

## Configs are committed data, not code

```json
{
  "prompt_source": {"inline_file": "priv/intent_eval/prompts/off_topic_default.txt"},
  "model": "classifier",
  "base_url": "http://192.0.2.10:8085/v1",
  "temperature": 0.0,
  "max_tokens": 1024,
  "chat_template_kwargs": {"enable_thinking": false},
  "buffering": {"debounce_ms": 0, "max_hold_ms": 0}
}
```

`prompt_source` is **explicit** and names exactly one of:

| kind | resolves to |
|---|---|
| `{"db_slug": "meetings.intent_classify.v1"}` | the LIVE `prompt_templates` row in this environment |
| `{"migration": "priv/repo/migrations/<file>.exs"}` | a heredoc module attribute read out of the migration source (never evaluated — evaluating would run `up/0` against a database) |
| `{"inline_file": "priv/intent_eval/prompts/<f>.txt"}` | a committed text file |

There is no "whatever the runtime would have used" default, **because that
default is the bug this stage exists to fix.** Three measurement runs over the
same 102 rows on 2026-08-26 reported 7, 8 and an unreproducible 23. The
discrepancy was not the model: one arm read the live `prompt_templates` row
while another read a migration heredoc, and neither instrument recorded which.
Every run now writes the resolved source **and** `sha256(rendered_prompt)` into
its manifest, so two runs that disagree are told apart in one `diff`.

`buffering.debounce_ms` must be `0`. The set is labelled per utterance, so the
harness classifies one row at a time; a non-zero merge window is **refused**
rather than silently ignored, because a config field that reads as applied but
is not is the same class of lie as an implicit prompt source.

## It measures the pipeline, not the model

Every row goes through `Platform.Meetings.IntentClassifier.decide/1` — the same
provider-call → parse → outcome path production walks. So `parse_error`,
`empty_output` and `model_error` are reported as **first-class error classes**
alongside the intent labels. They are never folded into `off_topic` and never
dropped.

`demoted` is reported too, but as an **outcome, not an error**. A positive that
fails the classifier's evidence gate is a successful classification downgraded
to `off_topic` — the pipeline really did decide `off_topic` — so a demoted row
keeps that prediction, is counted under `off_topic`, and carries no error class.
Until task `01a04379` it sat in the error taxonomy fed by an `{:error, {:demoted,
_}}` clause that `decide/1` can never return (its error reasons are bare atoms),
so the column printed **zero on every run ever published** while the
`binary_actionable` cassette was demoting 93 of its 174 rows. The error taxonomy
and the outcome taxonomy no longer share a bucket.

**A row that errored is not a row that declined.** Conflating the two is what
made 83 of 102 correct declines read as parse failures in one instrument on
2026-08-26, and the same defect is visible — now correctly named — in the
`off_topic_default` reference run below.

Output: per-class precision/recall/F1, a confusion matrix (error classes appear
as their own columns), a per-slice breakdown, error-class counts and latency
p50/p95. Human-readable to stdout; the same numbers to
`runs/<utc-timestamp>-<config>.json` next to the run manifest — config name and
sha256, prompt source and rendered sha256, model, base_url **host only**,
slice files and sha256s, harness git sha, wall clock.

## Task `01a06575` stage 4 — what this eval was NOT testing

The three numbers this set was best known for — `0.975` f1 on `off_topic`,
`59/60` firing on control, `3/102` false positives — were all true, all
reproducible, and all measured against a pipeline that was, at the same
time, producing **280 `meeting_candidates` in production and zero rows in
`tasks`**. None of them could move in response to that. Three things
were wrong with the instrument, and this stage addresses each:

### 1. The corpus tested speech nobody produces

Every positive row in `control_60` is explicitly agent-addressed —
*"Designer, make that primary button teal instead of the blue."*
`IntentFrames` already admitted it: *"The corpus cannot see that cost
because every control row is constructed to name a role."* Real meeting
speech does not name roles.

`slices/unaddressed_meeting_speech_48.jsonl` is 48 rows of unaddressed
speech with disfluencies, human owners, and no agent named anywhere.
**All 48 are HAND-WRITTEN and labelled as such.** (Until task `01a14dce`
one row was real transcribed speech. It named real people, so it was
replaced by an invented row of the same shape and label, tagged
`probe: former_verbatim`.) There was nothing to sample from: all 21
databases on the development host have zero rows in `meeting_transcripts`
and zero transcript segments. The same blindness that sank `control_60`
therefore applies to this slice too, and its header says so. Replace it
with sampled real segments the moment any environment has them.

It is **excluded from the default run** (`scored_by_default: false`)
because no cassette exists for it against any config and none can be
recorded while the endpoint is down. Every report names the exclusion and
its reason; it is never silently dropped. Reach it with
`--slice unaddressed_meeting_speech_48`.

### 2. The harness sent a different prompt than production

`Harness.assigns_for/1` hardcoded `correction_exemplars:
"(no prior corrections)"`. Production calls
`IntentCorrections.exemplars_for_meeting/2` — an unfiltered
`ORDER BY inserted_at DESC LIMIT 10` over the org's corrections, a table
whose own invariant is that it only holds records of the classifier being
WRONG. So the live prompt very likely carries up to ten negative
exemplars in a slot the prompt introduces as *"ground truth for this
org's vocabulary"*, and no published run has ever rendered one.

`correction_exemplars` is now a config source with three arms —
`sentinel` (the default, so every published fingerprint still
reproduces), `file`, and `db_recent` (the live query). All three render
through `IntentClassifier.format_correction_exemplars/1`, the function
the live classifier calls, so the eval and production cannot disagree
about the format. `db_recent` **raises** on an empty corpus rather than
degrading to the sentinel: production degrades on purpose, but an eval
arm that claims to render production's exemplars while rendering the
sentinel is publishing a number about a prompt it did not send.

**The score delta between the arms is NOT MEASURABLE.** Changing the
exemplar block changes the rendered prompt, hence every cassette key, so
replaying the sentinel arm's cassette under the exemplar arm is scoring
the model's answers to a different prompt. `Harness.run/2` refuses it
with a 174-row cassette miss. What IS measurable offline is the prompt:

```sh
mix platform.intent_eval.prompt --config off_topic_default \
  --diff off_topic_default_prod_exemplars
```

Measured 2026-09-02: same prompt body, different rendered prompt,
**+1177 bytes**, eight exemplars, **all eight `removed_no_action`** and
none carrying a `should have been:` line. The block is entirely pressure
toward `off_topic`.

### 3. Nothing in it reached a task row

The harness calls `IntentClassifier.decide/1` and stops. `decide/1` is a
provider call, a parse and an evidence check — it never touches the guard
chain, the debounce buffer, `IntentQueue`, the candidate mirror,
`IntentDispatcher`, the countdown, `Candidates.claim_due/2` or
`graduate/2`. The `task_id = 0/280` defect lived in `claim_due/2`.

`Platform.Meetings.IntentEval.E2E` plus
`test/integration/intent_eval_e2e_scoring_test.exs` drive labelled rows
through the whole chain to a row in `tasks`. The stub answers with each
row's gold label, so this arm measures **the plumbing, never the model** —
a `graduated` count of zero here can only mean the pipeline is broken.
Declines are scored too: an `off_topic` row must produce no task, and
without a running dispatcher it graduates into one.

Measured 2026-09-02 over `unaddressed_meeting_speech_48`:

```
graduated to a task     : 31 of 38 positives
correctly declined      : 10 of 10 declines
spurious tasks          : 0
two-sided correct       : 41 of 48
demoted by a gate       : 7
```

All seven losses are `IntentFrames`, not the pipeline:

  * **6 of 6 delegation rows** (`ask her to …`, `tell them to …`) are
    cancelled by `:frame_delegation` and reach no task. That gate
    justifies itself as *"off_topic by the prompt's own definition"* —
    the definition stage 3 removed. The conflict is now measured and
    pinned, and deliberately **not fixed**: narrowing a shipped gate is a
    decision, not a patch.
  * **1 new over-suppression this corpus found.** `:frame_retraction`'s
    lexicon contains `forget (it|that)`, which matches *"write that down
    somewhere before we forget it"* — where the phrase is an intensifier
    on the ask, the exact opposite of a retraction. No previously
    committed slice contained the idiom. Also pinned, also not fixed.

### What could not be produced

`http://192.0.2.10:8085/v1` is unreachable (curl exit 28, connection
timeout, verified 2026-09-02). So there is **no before/after per-class f1
for the stage-3 prompt and none for the exemplar arm**. Both are named
arms with recorded fingerprints (`unmerged_intent_target`,
`off_topic_default_prod_exemplars`) and neither has a cassette. Record
them the moment an endpoint returns:

```sh
mix platform.intent_eval.run --config unmerged_intent_target --record
mix platform.intent_eval.run --config off_topic_default_prod_exemplars --record
mix platform.intent_eval.run --config off_topic_default \
  --slice unaddressed_meeting_speech_48 --record
```

Do **not** replay `off_topic_default`'s cassette against either. It holds
the model's answers to the old prompt body, and scoring them against a
new one produces numbers that look like an answer and mean nothing.

## The two committed reference points

Recorded, not re-litigated. **If a replayed run does not reproduce these, that
is a finding about the harness to report — do not adjust these numbers to
match.**

### `off_topic_default` — the shipped reframe

The 2026-08-27 reference replay of `cassettes/off_topic_default.jsonl` as it
was then. Task `01a14dce` removed that run file from the tree with the other
pre-rename runs; the numbers below are its record.

| | expected | measured here |
|---|---|---|
| negatives firing (of 102) | 8 | **8** |
| control holding, i.e. firing (of 60) | 59 | **59** |

Both published figures reproduce exactly. The run also surfaced what the
published pair could not: **94 of the 102 negatives were `parse_error`, not
declines.** The model answers `{"intent": "off_topic", "target_role": null, …}`
— JSON `null`, exactly as the prompt's closed enum instructs — and
`parse_content`'s `when is_binary(target_role)` guard rejected it.

That defect is now fixed (task `01a03f57`), and replaying the same cassette
confirms the prediction made here: **the parse_error column collapsed into
`off_topic` — 94 of the 102 negatives are now scored as the correct declines
they always were, and whole-set `parse_error` went 96 → 0 — while the 8/102
firing figure did not move.** No cassette was re-recorded; the same recorded
bodies are simply no longer misread.

### `binary_actionable` — the pre-reframe binary arm

The 2026-08-27 reference replay of `cassettes/binary_actionable.jsonl` as it
was then (run file removed by task `01a14dce`; the numbers below are its record).

| | expected | measured here |
|---|---|---|
| negatives rejected (of 102) | 90 | **72** |
| control firing (of 60) | 3 | **54** |
| errors | 0 | **0** |
| median latency | 0.09 s | **0.185 s** |

**These do not reproduce, and that is reported rather than papered over.** The
cause is recorded in `configs/binary_actionable.json`: the binary prompt used on
2026-08-26 was never committed — that runner was deliberately throwaway and
out-of-repo (`~/sources/tmp/01a03f57-measure.py`) — so `prompts/binary_actionable.txt`
is a **reconstruction** of the described framing, not the original text. A
different prompt is a different arm, so a mismatch here is expected and is
exactly the class of ambiguity this harness removes going forward: from now on
every arm's prompt is committed and every run records its sha.

The control figure is also independently implausible on its face — a binary
"is this actionable?" prompt firing on only 3 of 60 genuine addressed asks
would be a near-total failure of the arm, while 54/60 is what the framing
predicts. Read the published `3 of 60` as describing a different instrument.

## The harness is shown to separate a good config from a broken one

**A harness that cannot be demonstrated to tell configs apart has not been
built.** The ticket's own bar: *a deliberately broken config must score badly —
a harness that reports success for everything is worse than none.* Three broken
configs are committed for exactly that, each with its own cassette so every
number replays with no network:

| config | what its prompt instructs | control_60 firing | negatives_102 firing | parse_error (of 174) | JSON bodies (of 174) | run |
|---|---|---|---|---|---|---|
| `off_topic_default` *(reference)* | the shipped reframe | **59 / 60** | **8 / 102** | 0 | 174 | 2026-08-27 reference replay |
| `broken_always_off_topic` | answer `off_topic` for everything | **0 / 60** | 0 / 102 | 0 | **174** | 2026-08-27 record run |
| `broken_never_off_topic` | never answer `off_topic` | 60 / 60 | **102 / 102** | 0 | 174 | 2026-08-27 record run |
| `broken_malformed_schema` | answer in prose, not JSON | 0 / 60 | 0 / 102 | 174 | **0** | 2026-08-27 record run |

**The `JSON bodies` column is why it is there.** Before the `target_role: null`
fix, `broken_always_off_topic` and `broken_malformed_schema` were byte-identical
on every other column — a model that declines everything in perfectly
well-formed JSON and a model that answers in prose printed the same report. The
fix pulled their `parse_error` counts apart (0 vs 174), but the shape column is
what made the conflation visible while that number was lying, so it stays. `summary["parseable_bodies"]` (stage 6)
counts responses that parse as a JSON object, is printed on the `JSON bodies`
line of the run report, and is the only number that separates those two failure
modes. Without it the next person comparing a candidate config is sent down the
wrong debugging path.

`binary_actionable` is deliberately absent from that table: stage 4 recorded that
its prompt is a labelled *reconstruction*, so it is a different arm, not a peer
of `off_topic_default`. See its own section below, caveat included.

The gaps are asserted in
`test/platform/mix/tasks/intent_eval_discrimination_test.exs`, which replays the
committed cassettes and so runs in CI with no network. **Its thresholds are
deliberately wide** — they catch a harness that cannot separate configs at all,
not a model's exact score. A tight threshold here becomes the flaky test
somebody deletes.

### Two findings from stage 5, recorded rather than tuned away

**1. "`parse_error` exceeds half the set" was a VACUOUS assertion**, so it is
not the assertion the test makes. It was vacuous because EVERYTHING errored:
`off_topic_default` landed 96 of 174 rows in `parse_error` (the `target_role:
null` guard defect described above) and `broken_always_off_topic` 174 of 174, so
the count separated nothing. Since the fix both land 0 of 174. The test still
compares `broken_malformed_schema` against `off_topic_default`'s background rate
**on the same slice** and against the recorded response *shape*, rather than
resting on a single headline number that only recently started telling the
truth.

**2. `broken_always_off_topic` now shows the shape the plan predicted.** It was
expected to be near-perfect on the 102 negatives and scored **0**, because its
perfectly-valid `{"target_role": null}` JSON was rejected before its correct
decline could be counted. The control was *not* edited to dodge this — and the
fix turned that 0 into **102 of 102**, from the same cassette. The consequence
worth naming is what the period before the fix looked like: the `parse_error`
class conflated 174 syntactically perfect JSON objects rejected by a field guard
with 174 answers that were not JSON at all, and only the response-shape column
(174 vs 0 JSON-parseable bodies) could tell them apart.

### The scoring was mutated to check the assertions actually fire

A green test proves nothing until it has been shown to go red. Each mutation
below was applied to `Harness`, the test re-run, and the mutation reverted:

| mutation | result |
|---|---|
| `predicted_intent/1` returns `"off_topic"` for error rows (fold `parse_error` into `off_topic`) | **1 failure** — *"an unparseable answer was counted as a decline"* |
| `fired?/1` drops its `is_nil(error_class)` guard (an error counts as a firing) | **3 failures** — control-slice, negative-slice and prose tests all red |
| `load_rows/2` drops `control_60` from the set (the control slice contributes nothing) | **3 failures** — both control tests and the background-rate comparison red |
| `demoted_count/1` returns a constant `0` (the counter never increments) | **3 failures** — the demotion case, the report case and the 93-row reference run red |
| `demoted_count/1` returns `length(scored)` (the counter increments unconditionally) | **5 failures** — both zero-demotion controls red as well as the three above |
| `demoted_count/1` counts `predicted == "off_topic"` (demotion read off the prediction) | **5 failures** — a genuine decline is not a demotion |
| `IntentClassifier.parse_content/3` drops `:demoted_from` from its demote branch | **3 failures** — the harness cannot see a demotion the classifier does not signal |
| `decide/1` sets `:demoted_from` on every `{:ok, _}` decision | **5 failures** — both directions of the counter red |

## Reproducibility is demonstrated, not asserted

`mix platform.intent_eval.run --config off_topic_default --replay` was run twice
on 2026-08-27, one second apart. Both runs were committed until task `01a14dce`
removed every pre-rename run file. Every scored number was identical; the two
files differed in exactly three fields —
`manifest.started_at`, `manifest.finished_at`, `manifest.wall_clock_seconds`.

The test asserts **that exact exclusion set** and byte-equality of everything
else, and separately asserts that the scrub removed something — a loose
comparison of a few headline numbers would pass on a harness that varied every
other score, and a scrub that quietly widened to cover everything would pass on
anything at all.

## Regenerating

```bash
# fresh numbers (needs the endpoint)
mix platform.intent_eval.run --config <name> --record

# reproduce a published number (needs nothing but this repo)
mix platform.intent_eval.run --config <name> --replay
```

Re-recording rewrites `cassettes/<config>.jsonl` in key order, so a re-record
produces a readable diff rather than an append-only log.

## Fragment baseline — task `01a03fb9` stage 1

Measurement only; no production behaviour changed. Reproduce with:

```bash
mix platform.intent_eval.run --config off_topic_default --replay
python3 priv/intent_eval/analysis/fragment_split.py <the run file> \
        --json priv/intent_eval/analysis/fragment_baseline.json
```

Numbers below are from `off_topic_default` replayed at harness sha
`62f355b0`, prompt `1fc55bf8…`, slice `2529c5eb…`. Two consecutive replays
produced identical counts. `analysis/fragment_baseline.json` is that
measurement's record and keeps its ids as measured: since task `01a14dce`
replaced a person name in one negatives row, that row's id
`f243245d6f795199` is now `76f625224f9d7817`.

### The headline

| | count |
|---|---|
| negatives_102 rows | 102 |
| **false positives (fired)** | **8** |
| correct declines | 94 |
| errors | 0 |
| **false positives that are FRAGMENTS** | **1 of 8** |
| **false positives that are COMPLETE utterances** | **7 of 8** |
| fragments anywhere in the slice | 33 of 102 (32.4%) |
| of those 33 fragments, already declined | 32 |

### The ticket's premise does not hold against current main

The ticket names four fragments and the intents it says were assigned
(`visual_adjust`, `action_items`, `open_question`, `open_question`). All four
texts **are** in the corpus and **are** genuine recorded `removed_no_action`
corrections — that much verifies. But under the shipped `off_topic_default`
config **all four are already declined** (`predicted=off_topic`, `fired=false`,
ids `d6569608`, `bcc5860e`, `d02d9f24`, `58b53b40`).

They read as misclassified in the pre-fix reference run only because they
landed in `parse_error` — the `target_role: null` guard defect described
above, fixed under task `01a03f57`. Replaying the same cassette on current
code scores them as the correct declines they always were.

The intents the ticket quotes could not be confirmed: neither the slice nor
the fixture records the *predicted* intent, only the ground-truth label and
the correction `reason`, and `meeting_intent_corrections` is empty in every
database on this box.

### Fragment definition

Cheap lexical signals only — **no model call per row**, which is the cost this
ticket exists to avoid. A row is a fragment if **either**:

* **F1** — it does not end in `.` `?` `!` `…`. The STT emits terminal
  punctuation when it believes a sentence completed; a VAD cut on silence
  mid-thought does not get one.
* **F2** — it begins with a lowercase letter, i.e. it continues a segment that
  was emitted separately.

**Silence duration and speaker change are NOT available here.** The recorded
corpus preserves only `text`; both signals exist in the live pipeline but were
not carried into the slices. Any gate built on them cannot be scored against
this corpus without re-deriving it from the transcripts.

### Hand-check

All 33 fragment-flagged rows and a 20-row sample of the complete-flagged rows
were read by hand.

* **Over-flagging**: ~4 of 33 are continuation segments that nonetheless carry
  a complete clause — F2 catches the lowercase start and calls them fragments.
  This error direction **inflates** the fragment count, so it is conservative
  with respect to the conclusion below.
* **Under-flagging**: ~3 of 20 sampled completes are truncated mid-thought but
  carry a spurious terminal period from the STT, so F1 misses them.
* **Neither error touches the headline.** All 7 complete-utterance false
  positives are unambiguously well-formed sentences on inspection, and the 1
  fragment false positive is unambiguous. The 1/7 split is robust to both
  failure modes of the definition.

### Verdict on the task

**The fragment share of the reachable error budget is 1 of 8.** The classifier
already declines 32 of the 33 fragments in the slice. A fragment gate — buffer
or rolling window — can therefore remove **at most one** of the eight remaining
false positives, and the four fragments the ticket offers as its evidence are
already handled.

This task cannot deliver the win the ticket claims. The residual false
positives are complete, well-formed utterances that a completeness gate does
not address; they are a classifier-accuracy problem, which is the sibling
ticket `01a03f57-362a`.

## Task `01a05997` stage 4 — the `agent_roster` arm, scored on both arms

Stage 3 rewrote `meetings.intent_classify` so its addressing rule is stated
against the org's AGENT ROSTER. `configs/agent_roster.json` is that revision as
an eval arm; `slices/delegation_probe.jsonl` (9 rows) is the slice authored to
find out whether it *discriminates* or merely *fires*.

The slice is built out of minimal pairs. `Dalton file a ticket for the
purse-based meeting problem.` is the brief's reproduction utterance with the
transcript's `Octavius` replaced by the agent actually assigned
`triage_officer` on the production roster (read from `role_assignments JOIN
agents` on 2026-08-31 and pinned verbatim in the config's `agent_roster` field).
`Octavius file a ticket for the purse-based meeting problem.` is kept as an
`off_topic` row: byte-identical except for a name the roster does not contain.
Four further off-roster asks and the brief's two controls make up the rest.

### The numbers (replayed from the committed cassettes, no network)

| slice | `off_topic_default` (baseline) | `agent_roster` |
|---|---|---|
| `negatives_102` — off_topic correct | **99 / 102** (3 fired) | **96 / 102** (6 fired) |
| `control_60` — fired / correct | 59 / 47 | 59 / 48 |
| `unaddressed_probe_12` — fired / correct | 11 / 9 | 11 / 9 |
| `delegation_probe` — positives routable | **0 / 2** | **2 / 2**, both cited |
| `delegation_probe` — off-roster rows false-firing | 4 / 7 | **5 / 7** |

Runs: the 2026-08-31 replays of `off_topic_default` and `agent_roster`, and
the `agent_roster` `--record` run that produced that cassette (all three
removed from the tree by task `01a14dce`; the numbers here are their record).

### The margin, stated before the verdict

**A drop of more than 2 rows in `negatives_102` off_topic accuracy is a
regression, not noise.** 2 rows is the observed noise floor of the instrument,
not a round number: two `--record` runs of the identical 183 rows against the
same llama-server three minutes apart returned `negatives_102` correct = 94 and
= 96. `temperature: 0` does not make that endpoint deterministic. Anything
inside ±2 rows is unattributable; anything outside it is a real move.

### Verdict: the rebalance fixes the reproduction and does NOT discriminate

The positive arm passes. The reproduction utterance goes from `off_topic` to a
routable, cited intent carrying `target_role: triage_officer` — the dispatcher
can act on it and the human has a quote to judge. (Its *intent* is
`action_items`, not the labelled `open_question`; it reaches the right role by
the wrong road. Pinned in `delegation_probe_test.exs` rather than smoothed.)

The negative arm does not, on two counts:

1. **`negatives_102` off_topic accuracy falls 99 → 96, a 3-row drop that
   exceeds the stated 2-row margin.** Small, but outside the noise floor and in
   the wrong direction.
2. **The roster is not doing the work.** `Octavius file a ticket …` fires
   routable exactly like the `Dalton` twin, and 5 of the 7 off-roster rows
   false-fire against the baseline's 4. The prompt states in as many words that
   a name off the roster is a person; the model is not using it. What moved is
   its willingness to fire on a ticket-filing ask — the exemplars — not its
   ability to tell an agent from a person.

**This is reported, not tuned away.** Iterating the prompt until
`negatives_102` came back would produce a config that scores well on the arm it
was tuned against and still cannot tell `Dalton` from `Octavius` — a landslide
with a green gate, which is the specific failure this slice exists to catch.

`test/platform/meetings/intent_eval/delegation_probe_test.exs` pins all of it,
and is shown going red against `broken_never_off_topic`: 4 of its 8 tests fail
there, including both controls and the twin comparison.

## Task 01a05997 stage 5 — the addressee gate closes the discrimination arm

Stage 4's verdict is the reason stage 5 did **not** touch the prompt again. The
rendered prompt already states the roster rule verbatim three times (the
addressing rule, the `"Nah, I'm gonna get <person> in here."` exemplar, and
the `<person>, file a ticket…` contrast; since task `01a14dce` the person is
the invented name Sam). A fourth restatement is not a fix, and the
measured effect of the third was on *willingness to fire*, not on
discrimination.

`Platform.Meetings.IntentAddressee` converts the instruction into a checkable
invariant: after the model answers, a routable answer whose **addressed name**
(the utterance's vocative, or the leading vocative of the model's own
`evidence_quote`) does not appear in the roster the model was shown is demoted
to `off_topic` with `demotion_reason: :off_roster_addressee`. The roster is
threaded from the same read that rendered `{{agent_roster}}`, so the gate can
never judge an answer against a roster the model did not see. An utterance with
**no vocative** is never gated — `unaddressed_probe_12` is twelve legitimate
positives that address nobody — and roster ROLE KEYS count as addressable,
because `control_60` addresses agents as `Designer` / `Scribe` / `Historian` /
`Triage`.

Same cassette, `--replay`, so these are exact, not sampled — the ±2 noise floor
above applies to `--record` runs and does not apply here:

| slice | `agent_roster`, gate off | `agent_roster`, gate on |
|---|---|---|
| `negatives_102` — off_topic correct | 96 / 102 (6 fired) | **97 / 102** (5 fired) |
| `control_60` — fired / correct | 59 / 48 | 59 / 48 |
| `unaddressed_probe_12` — fired / correct | 11 / 9 | 11 / 9 |
| `delegation_probe` — positives routable | 2 / 2, both cited | **2 / 2, both cited** |
| `delegation_probe` — off-roster rows false-firing | **5 / 7** | **0 / 7** |

The single `negatives_102` row the gate moves is the one whose opening word
is a mis-transcription read as a vocative (since the pre-public scrub its
synthetic stand-in is `"Tap, can you tap the link and check what comes up?"`). It is
+1, it is inside the noise floor of the recording instrument, and **it is not
the result being claimed**. The result is the `delegation_probe` row: 5 → 0
off-roster false fires with the positives untouched.

What this does **not** fix: the model still answers a routable intent on every
one of those five rows. The gate rejects the answer; it does not improve it.
`delegation_probe_test.exs` asserts both halves — the model's wrong answer AND
the gate's correction — so a future revision that genuinely teaches the model
the roster shows up as a red test rather than hiding behind the gate.

A gate-rejected row is distinguishable from a model `off_topic` by a dedicated
`[:platform, :meetings, :intent_classifier, :off_roster_addressee]` telemetry
event, its own log line, and the `demotion_reason` column on every scored
harness row. It is **not** yet distinguishable in `meeting_candidates` — that
table has no column for it and none was invented here; persisting it would
need a nullable `demotion_reason` column and a matching `@writable_fields`
entry on `IntentQueue.Server`.

**Post-ruling contract (task 01a08fde, 2026-09-11, the product owner: gate).** The
addressee gate no longer demotes. Aligned with migration `20260902140000`, an
off-roster ask KEEPS the model's intent and verbatim `evidence_quote`, takes
`target_role: "null"` (the sentinel), and the scored row carries a new
`addressee_nulled_from` column holding the role the gate overwrote
(`triage_officer` for the off-roster twin). `demoted_from` /
`demotion_reason` stay `nil` on such a row, and the summary counts it under
`addressee_nulled` — its own outcome bucket, outside `demoted` and outside
`error_classes`. `Harness.routes_to_role?/1` (`fired?/1` AND a routable
`target_role`) is the property the `delegation_probe` number is now stated on:
the same 08-31 cassette scores 0 / 7 off-roster rows routing to a role, while
all five still `fired?/1` with `target_role: "null"`. The slice labels for
those five are still `off_topic` (the 08-31 person=off_topic rule, frozen as a
measurement), so the arm's per-slice `correct` drops from 7 to 2 by design;
`delegation_probe_test.exs` asserts that value explicitly rather than
relabelling.

## Task `01a14dce` stage 2 — real names replaced, cassettes re-recorded

Core is going public, so this set may carry no real person, org or client
name. Every slice row, prompt exemplar and test that named one now uses an
invented name instead: people Alex, Sam, Riley and Casey, org Acme, client
org Globex and client product Atlas. Each changed row keeps its label, its
addressee status (on the roster or not) and its probe tag, and its `id` was
recomputed from the new text. The one real utterance in
`unaddressed_meeting_speech_48` is now an invented row of the same shape
(`probe: former_verbatim`). 23 of the 183 default-run rows changed, and so
did one exemplar line in `prompts/off_topic_default.txt` and three in
`prompts/agent_roster_20260831.txt`.

**Re-recorded, never re-keyed.** A cassette key is
`sha256(rendered_prompt <NUL> chunk_text)`. Every row whose key changed was
asked again, live, on the same local llama-server (`classifier`, a 1.7B
gguf, at `localhost:8085`, host network, no API key). A row whose key did
NOT change kept its recorded answer, because that answer is the model's
answer to byte-identical input. The cassettes already mixed recording dates
before this (174 rows from 08-27 plus 9 from 08-31).

| config | rows asked live | rows kept |
|---|---|---|
| `off_topic_default` | 183 (the prompt changed) | 0 |
| `agent_roster_20260831` | 183 (the prompt changed) | 0 |
| `binary_actionable`, `broken_always_off_topic`, `broken_malformed_schema`, `broken_never_off_topic` | 23 each | 160 each |

That is 458 live calls, plus 183 more for the scratch run below.

**The eleven pre-rename run files left the tree.** Their rows, recorded
answers and manifests carried real names and a LAN address, and a historical
record cannot be neutralised without falsifying it. They went to a private
record with a sha256 manifest. The six committed runs in `runs/` are replays
of the new cassettes (no network), and their `base_url_host` is
`localhost:8085`. The sections above quote the old runs' numbers by date.

### Scores: old committed, old text today, new text today

"Old text today" is the old cassette replayed at the pre-task tree
(`cc917d8e`). For `off_topic_default` it is also a scratch `--record` run
of the OLD prompt and OLD slices against today's model, which was never
committed. That live run matched the old cassette on all 183 rows, so on
this day the endpoint reproduced the old answers exactly. "Old committed"
is the last committed run for the config: the 2026-08-31 replays for the
first two configs. For the other four it is the 2026-08-27 runs, which had
174 rows and older scoring code (the `target_role: null` parse defect), so
those are not like-for-like. Accuracy is correct rows over all rows.

| config | metric | old committed | old text today | new text today |
|---|---|---|---|---|
| `off_topic_default` | accuracy | 0.8634 (158/183) | 0.8634 (158/183) | **0.8525 (156/183)** |
| | macro F1 / off_topic F1 | 0.729 / 0.9489 | 0.729 / 0.9489 | **0.7073** / 0.9489 |
| | negatives fired / control fired / probe fired | 3 / 59 / 11 | 3 / 59 / 11 | 3 / 59 / 11 |
| | control correct / demoted / errors | 47 / 5 / 0 | 47 / 5 / 0 | **45** / 4 / 0 |
| `agent_roster_20260831` | accuracy | 0.847 (155/183) | 0.847 (155/183) | **0.8415 (154/183)** |
| | macro F1 / off_topic F1 | 0.7425 / 0.9378 | 0.7425 / 0.9378 | 0.7588 / **0.9275** |
| | negatives correct (fired) / control correct | 96 (6) / 48 | 96 (6) / 48 | **94 (8)** / 49 |
| | delegation off-roster routing to a role / addressee_nulled | 5 / — | 0 / 6 | 0 / 6 |
| `binary_actionable` | accuracy / demoted | 0.4138 (174 rows) / — | 0.5956 / 100 | 0.5956 / 99 |
| `broken_always_off_topic` | accuracy / errors | 0.0 / 174 (174 rows) | 0.5956 / 0 | 0.5956 / 0 |
| `broken_malformed_schema` | accuracy / parse_error / JSON bodies | 0.0 / 174 / — (174 rows) | 0.0 / 183 / 0 | 0.0 / 183 / 0 |
| `broken_never_off_topic` | accuracy / negatives fired | 0.3448 / 102 (174 rows) | 0.377 / 94 | 0.377 / 94 |

**Findings: two configs score lower on the new text, and they are reported
here, not tuned away.**

1. `off_topic_default`: accuracy 0.8634 → 0.8525 and macro F1 0.729 → 0.7073.
   Two control rows whose text did NOT change (`slices/control_60.jsonl:38`
   and `:49`) now get the wrong intent. The only thing that changed for those
   rows is the prompt: one name in one exemplar line. Every firing count holds.
   One negatives row (`slices/negatives_102.jsonl:14`) is now declined by the
   model itself instead of being demoted by the frame gate.
2. `agent_roster_20260831`: accuracy 0.847 → 0.8415 and off_topic F1
   0.9378 → 0.9275. Two negatives whose text did not change
   (`slices/negatives_102.jsonl:40` and `:63`) now fire. That is the same
   size as the ±2-row `--record` noise floor recorded above. This arm had no
   old-text live run (only one scratch run was budgeted, for
   `off_topic_default`), so its "old text today" column is a replay. The
   `off_topic_default` scratch run reproduced its old answers exactly on the
   same day, which points at the one-name prompt edit rather than noise. It
   does not prove it for this arm. Macro F1 rose (0.7425 → 0.7588),
   because `control_60.jsonl:20` became correct. The delegation numbers this
   arm is pinned on (4 shipped / 5 roster-prompt / 0 with the gate) all hold.

The four configs whose prompt did not change score the same except for one
`binary_actionable` demotion (93 → 92 on the 174 seed rows), which is on a
rewritten row.

## Synthetic negatives (pre-public scrub)

`negatives_102` was normalised from recorded producer removals: real
utterances from real meetings, with names replaced by task `01a14dce` but the
speech itself still transcribed. Before Core went public all 102 rows were
replaced with SYNTHETIC stand-ins, one per original row, in the same order:

* each row was hand-written to keep the shape of the row it replaced: its
  `source_reason`, its length class, whether it is a fragment (33 of 102, by
  the F1/F2 rule in `analysis/fragment_split.py`), and the lexical feature the
  gates and tests key on (the retraction, perception, epistemic, delegation
  and evaluative frames; three hortatives and two peer-agreement rows; the
  `transcriber` word-boundary row; the mis-transcribed vocative). Content and
  names are invented (Alex, Sam, Riley, Casey, Acme, Globex, Atlas);
* every row is `origin: "synthetic"` and its `id` is recomputed from the new
  text; `test/support/fixtures/intent_classify_negatives.jsonl` carries the
  same texts and reasons, and `exemplars/recorded_removals_8.jsonl` the same
  eight rows it always paired with;
* no live model was called. For each of the six cassettes, the entry recorded
  for an original row was re-keyed to `sha256(rendered_prompt <NUL> new_text)`,
  computed by the harness's own render path, and its answer kept: same intent,
  `target_role`, confidence and response shape, with `evidence_quote` (and the
  `dedupe_key` derived from it) rewritten to the matching span of the new
  text, or to a span that is NOT in it where the original quote was not in its
  chunk. `broken_malformed_schema` prose was rewritten around the new text.
  Every such entry carries `"synthetic": true`. These are hand-derived
  answers to inputs the model never saw, so they measure the HARNESS and the
  gates, not the model: do not quote a model number from the negatives rows.

Every replay was compared row by row before and after, across all six configs
and all four default slices: predicted intent, demotion and its reason, error
class, `target_role` and `addressee_nulled_from` match on all 183 rows, so
every number above still reproduces. The six runs in `runs/` were rewritten
from the new cassettes with no network. `SyntheticFixtureGuardTest` keeps it
this way: it fails on a full UUID, a speaker or meeting id field, a
diarisation label, or a `negatives_102` row that is not synthetic.

Not changed, and stated so it is not mistaken for scrubbed: the classifier
prompts (`prompts/*.txt` and the migrations that ship them) still carry three
short worked examples taken from the original removals, because the prompt
bytes are part of every cassette key and of what a fresh install seeds; and
`analysis/fragment_baseline.json` still names the original row ids.
