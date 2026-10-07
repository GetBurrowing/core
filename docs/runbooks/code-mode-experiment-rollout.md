# Code-mode experiment rollout

Task `01a114a8` stage 4. This runbook turns the code-mode experiment on in
production after the branch merges and deploys. **Run nothing here before
then:** the `dispatch.code_mode` surface, the `agent_id` cohort key,
`code_mode_report` and the `code_mode` bundle do not exist in production until
the deploy lands. Every step is data or per-host config. None of it is a code
change or a deploy.

If any step below disagrees with what you measure, stop and record the
measurement in the task's execution space. Do not adapt the step quietly.

## What gets built, and what this runbook does

| Built by the branch (stages 1-4)                         | Done here, after deploy                          |
|----------------------------------------------------------|--------------------------------------------------|
| `dispatch_tool_calls` ledger, `DispatchMetrics`          | grant `code_mode` to the five runtimes           |
| `suite_run` / `suite_run_describe` (`code_mode` bundle)  | `experiment_create`, `experiment_variant_add`, `experiment_start` |
| `dispatch.code_mode` surface, `agent_id` cohort key      | install the usage hook on each Claude Code host  |
| directive on planning, in_progress and review prompts    | the dsh `usage_event` change (separate repo)     |
| `dispatch_usage` metric kind, `code_mode_report`         | the Oddjob unit fix                              |
|                                                          | read `code_mode_report`, publish the canvas      |

## Roster

Measured with `federation_status` at 2026-10-07 04:42Z. Re-read it before you
start. A runtime id can change if an agent is re-provisioned.

| Agent   | agent_id                               | runtime_id           | Harness / host           | Status then |
|---------|----------------------------------------|----------------------|--------------------------|-------------|
| Brosnan | `019f7d30-4a54-7730-aecc-5df5caa400b9` | `brosnan`            | Claude Code, rock        | online      |
| Dalton  | `019dc658-b64c-7deb-bad7-c34d86924e32` | `rowan-claude-agent-1`| Claude Code, hive        | online      |
| Moore   | `019f9b0b-aadb-73f9-9564-2aa59d349a09` | `rowan-claude-moore`  | Claude Code, rock        | online      |
| Oddjob  | `01a054e0-470b-7001-afc4-331957a2bbb1` | `oddjob-dsh`         | DeepSeek harness, hive   | OFFLINE since 2026-10-03T14:18Z |
| Geordi  | `019d9e54-c297-7165-b72d-9d3019d3e911` | `rowan-coder`         | OpenClaw (gpt-5.6), its own host | online |

Higgins and Mycroft run local models. They are candidates for a later
weak-model cohort, not this run.

## Step 0: preflight (read only)

1. Confirm the deploy carries the stage 4 commit. Call
   `experiment_surface_list` and check that `dispatch.code_mode` appears
   with `targets: ["dispatch.prompt_directive"]`. If it is missing, stop:
   the deploy has not landed.
2. Call `federation_status` with
   `{"runtime_ids": ["brosnan", "rowan-claude-agent-1", "rowan-claude-moore", "oddjob-dsh", "rowan-coder"], "fields": ["agent_slug", "online", "last_seen_at"]}`.
   Record the output in the execution space.
3. Moore's ack capability. Call `runtime_event_list` for Moore's recent
   tasks and look for `execution.acked` rows from `rowan-claude-moore`. Stage 1
   found Moore's only done task used `alarm_silence` and never acked, which
   suggests Moore's MCP client cache lacks `task_ack`. **That does not stop
   enrolment.** Moore's dispatches are still measured as `stage_row` units
   (see "Reading the report"). But record what you found, because it decides
   how you read Moore's rows.
4. Oddjob. If `oddjob-dsh` is offline, do Step 5 first. Enrol Oddjob only if
   it has held a connection for 24 h. Otherwise leave it out of the cohort
   (Step 2) and record why.

## Step 1: grant the `code_mode` bundle (Control Center)

`code_mode` is grantable and not a default. A treatment-arm prompt tells the
agent to call `suite_run`. A runtime without the grant would be told to use a
tool it cannot call, so **grant first, then create the experiment.**

For each enrolled runtime: open `/control/<agent_slug>` (`brosnan`, `dalton`,
`moore`, `oddjob`, `geordi`), open the runtime panel, and tick **code_mode** in
the allowed bundles. This writes `Federation.update_allowed_bundles/2`. There
is no deploy and no restart.

Keep the other bundles as they are. To check, the runtime's `tools/list` now
includes `suite_run` and `suite_run_describe`.

**Brosnan, Dalton and Moore: their MCP client caches the tool list at
session start.** The grant reaches each agent at its next session start.
Never restart a live agent session to hurry it. Until it lands, a
treatment-arm prompt to that agent names a tool the agent does not see, and
the report will show low `suite_run_adoption_rate` for that agent. That is a
real measurement of the rollout state, not a bug.

## Step 2: create and start the experiment (MCP)

Run these as an UNPINNED runtime (Dalton's). The experiment is install-wide
(`org_id` null) because the five agents work across projects. Only an
unpinned runtime may create an install-wide experiment.

### 2a. `experiment_create`

```json
{
  "surface_key": "dispatch.code_mode",
  "surface_target": "dispatch.prompt_directive",
  "name": "Code mode: suite_run vs direct tool calls",
  "slug": "code-mode-2026-10",
  "hypothesis": "Told to work through suite_run, an agent makes fewer model-issued Suite tool calls and fewer turns per dispatch, with first-pass outcome no worse. Arm is per task, stratified by agent: each agent is compared with itself.",
  "metric_spec": {"kind": "dispatch_usage", "field": "suite_tool_calls", "agg": "median"},
  "assignment_policy": {
    "type": "task_cohort",
    "cohort": {
      "agent_id": [
        "019f7d30-4a54-7730-aecc-5df5caa400b9",
        "019dc658-b64c-7deb-bad7-c34d86924e32",
        "019f9b0b-aadb-73f9-9564-2aa59d349a09",
        "01a054e0-470b-7001-afc4-331957a2bbb1",
        "019d9e54-c297-7165-b72d-9d3019d3e911"
      ]
    }
  },
  "stop_rule": {"min_subjects": 10}
}
```

- Drop Oddjob's id (`01a054e0-…`) from `agent_id` if Step 0 left it out.
- `min_subjects` counts DISPATCHES for `dispatch_usage` metrics, and
  `code_mode_report` withholds every per-agent figure below it (`n` is always
  shown). 10 dispatches per agent and arm is the floor for reading a median,
  not a significance claim.
- A refusal of `surface_not_allowed` means a stored guardrail row narrows the
  allowed surfaces. A person adds `dispatch.code_mode` in the experiments
  admin. Do not route around it.

### 2b. `experiment_variant_add`

```json
{"experiment_id": "<id from 2a>", "slug": "treatment", "payload": {"suite_run": true}, "weight": 1}
```

The control arm is captured at start as `{"suite_run": false}` with weight 1.
With both weights at 1 the split is 50/50 per task.

### 2c. `experiment_start`

```json
{"experiment_id": "<id from 2a>"}
```

`result: "pending_human_approval"` is success when the org requires launch
approval: a person approves it in the UI. `surface_busy` means another running
experiment holds `dispatch.code_mode`. Read it with `experiment_list` before
you do anything else.

### What happens next

Each dispatch render of a task (planning, in_progress, review) asks the
surface for the task's arm. It uses the DISPATCHED PHASE's agent assignee as
`agent_id`:

- A task whose phase assignee is in the cohort is assigned once and stays in
  that arm. The treatment prompt ends with the
  `## Experiment directive (dispatch.code_mode)` primer. The control prompt
  ends with "Code mode is OFF for this task: do not call suite_run on this
  task."
- A task whose phase assignee is not in the cohort gets no block, and its
  prompt is byte-identical to a render with no experiment.
- A task first rendered for a non-cohort planner, then dispatched to a cohort
  executor, is assigned at the executor's render.

Data accrues only as fast as these agents receive dispatches. Planning
dispatches are not measured units (they carry no stage), so a task contributes
one dispatch per stage it runs.

## Step 3: install the usage hook (Claude Code hosts)

`scripts/agent-hooks/claude-code-dispatch-usage.py` (stage 1) reads a
finished session's transcript, counts turns, tool calls and tokens, and POSTs
one row to `/api/internal/usage-events`. Without it, a Claude Code agent's
`client_*` metrics are null, never 0.

**Each agent installs it on its OWN host, in its own config: Dalton on hive,
Brosnan and Moore on rock.** No agent edits another agent's config. Never
restart a live agent session to load it. Claude Code reads hooks at session
start, so the hook takes effect at the next session.

1. Self-test, no network:

   ```bash
   python3 <core checkout>/scripts/agent-hooks/claude-code-dispatch-usage.py --self-test
   ```

   Expect `SELF-TEST OK`.

2. Put the three values in a file only the agent's user can read, for
   example `~/.config/suite/usage-hook.env` with mode 0600:

   ```
   SUITE_BASE_URL=https://suite.example.com
   SUITE_AGENT_ID=<the agent's id from the roster>
   SUITE_RUNTIME_TOKEN=<the runtime bearer token>
   ```

   Copy the token from wherever the agent already keeps it (for Dalton, the
   bearer in its `.mcp.json`). Do it with a file-to-file copy (`jq -r`
   into the env file, for example). **Never print it, never paste it into a
   chat, a ticket or `settings.json`, and never run `cat` on the env file.**
   Add `CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET` only if the base URL
   sits behind Cloudflare Access for that host.

3. A wrapper that loads the file and runs the hook, for example
   `~/.config/suite/usage-hook.sh` (mode 0700):

   ```bash
   #!/usr/bin/env bash
   set -a; . "$HOME/.config/suite/usage-hook.env"; set +a
   exec python3 /path/to/claude-code-dispatch-usage.py
   ```

4. Register it for both events in the agent's own Claude Code settings
   (`~/.claude/settings.json`, or the agent directory's
   `.claude/settings.json`). Merge it with any existing `hooks` key and do
   not replace that key:

   ```json
   {
     "hooks": {
       "SubagentStop": [{"hooks": [{"type": "command", "command": "$HOME/.config/suite/usage-hook.sh"}]}],
       "Stop": [{"hooks": [{"type": "command", "command": "$HOME/.config/suite/usage-hook.sh"}]}]
     }
   }
   ```

   `SubagentStop` covers dispatches the agent hands to a subagent (Dalton's
   pattern). `Stop` covers dispatches the main session works itself. A
   session with no task id in its first user message sends nothing.

5. Verify on the agent's next dispatch: `dispatch_metrics_list` with
   `{"agent_id": "<id>", "task_id": "<that task>"}` shows `client_reports`
   ≥ 1 and non-null `client_turns`. A dry run that reads a real transcript
   without sending:
   `python3 …/claude-code-dispatch-usage.py --dry-run < hook.json`.

Geordi (OpenClaw) already sends `usage_event` frames carrying the task. It
needs no hook. Check its `client_reports` the same way.

## Step 4: dsh `usage_event` gains task_id and stage_id (separate PR)

**This change lives in the dsh-suite repo, not in core.** Open it as its own
small PR there. The copy at `~/sources/dsh-suite` on hive is NOT a git
checkout, so edit and commit in the real dsh-suite repository.

Today `plugins/suite-federation/index.js` (around line 255) pushes
`usage_event` with `metadata: {harness: 'dsh', runtime_id}` and no task. A
report without `task_id` can never match a dispatch, so every Oddjob
`client_*` figure is null. The change, inside `handleAttention(payload)`
where the frame is pushed:

```js
const taskId = payload.signal?.task_id ?? null
const runningStage = payload.context?.plan?.stages?.find((s) => s.status === 'running')

channel?.push('usage_event', {
  // ...the existing fields...
  task_id: taskId,
  metadata: {
    harness: 'dsh',
    runtime_id: runtimeId,
    ...(runningStage?.id ? { stage_id: runningStage.id } : {}),
  },
})
```

`signal.task_id` is set by `TaskRouter.dispatch_attention/5`. The plan is
`ContextAssembler.build/1`'s `plan` key. Check the serialized stage keys
against `serialize_plan` in `context_assembler.ex` before merging. Send no
`turns` the harness cannot count. A missing field reads as null, and a
fabricated 0 reads as a measurement.

## Step 5: Oddjob's unit

Oddjob's user unit (`~/.config/systemd/user/oddjob.service` on hive) is
`Type=oneshot` + `RemainAfterExit=yes`. It launches a tmux session through
`~/agents/oddjob/run.sh`. So the unit reads `active (exited)` whether or not
the agent process is alive, and nothing restarts it. It has been offline
since 2026-10-03T14:18Z while systemd reported it active.

Whoever owns Oddjob makes this change. It is not part of this task's branch.

1. Check that `~/sources/dsh-suite/run-oddjob.sh` runs in the foreground with no
   TTY. It `exec`s `dsh --profile headless`. Run it once in a scratch tmux
   pane and watch for `JOIN-OK` in its stderr. The unit's own comment says
   the tmux layer exists because `suite deepseek` needs a terminal. The
   headless profile is meant not to, so verify that before you switch.
2. If it holds, replace the service body:

   ```ini
   [Service]
   Type=simple
   WorkingDirectory=/home/dev/agents/oddjob
   ExecStart=/home/dev/sources/dsh-suite/run-oddjob.sh
   Restart=on-failure
   RestartSec=30
   StandardOutput=append:/home/dev/agents/oddjob/oddjob.log
   StandardError=append:/home/dev/agents/oddjob/oddjob.log
   ```

   Then `systemctl --user daemon-reload && systemctl --user restart oddjob`.
   Never paste or print the contents of `.env.suite` or `.env.oddjob`.
3. Watch `federation_status` for `oddjob-dsh` for 24 h. If it does not hold a
   connection that long, leave Oddjob out of the cohort. If the experiment is
   already running with Oddjob in it, `experiment_exclude` each of Oddjob's
   assigned tasks with the reason, for example
   `{"experiment_id": "…", "subject_id": "<task>", "reason": "oddjob-dsh could not hold a connection for 24 h"}`.
   Geordi stays the non-Anthropic arm either way.

## Step 6: read `code_mode_report`

```json
{"experiment_id": "<id>"}
```

It returns one row per **dispatched agent × arm**. Each cohort agent gets a
row for both arms even with no dispatch (`n: 0`), so an enrolled agent that
produces nothing is visible, not absent. Agents outside the cohort show up
too when they were dispatched on an enrolled task, for example a reviewer.

Read each row in this order:

1. **`coverage` first. It decides whether the agent's figures mean anything.**
   - `unit_source` / `ack_pct`: how the agent's dispatches were found. `ack`
     units start at the agent's `task_ack`. `stage_row` units belong to an
     agent that never acked, start at `stages.started_at` (earlier), and
     cannot see a re-dispatch. **An agent at `ack_pct: 0.0` cannot ack.
     Expect this for Moore.** That agent's wall times are not comparable with
     other agents', but its two arms are comparable with each other, because
     both use the same clock.
   - `attribution_pct` / `attribution_by_rung`: the share of the agent's
     model-issued Suite calls since the first assignment that the ledger tied
     to a task. Unattributed calls count toward no dispatch, so a low figure
     means the agent's `suite_tool_calls` undercount. Both arms of one agent
     carry the same figure, because an unattributed call cannot be put in an
     arm.
   - `client_report_pct`: the share of dispatches with a usage report. 0 means
     the hook (Step 3) or the dsh change (Step 4) is not live for that agent.
     Its `client_*` metrics will be null, never 0.
2. **`n` and `tasks`.** `n` counts dispatches, not tasks. Every metric
   carries its own `n`, the number of dispatches that had the field. Its
   `value` is null with `reason: "below_stop_rule"` until `n` reaches
   `min_subjects`. Report the dispatches per cell whenever you report a figure.
3. **Compliance.** `suite_run_adoption_rate` (treatment): the share of
   dispatches with at least one `suite_run` call. A low rate means the agent
   ignored or could not see the directive. Check the bundle grant has reached
   its session before you read the outcome. `control_suite_run_violations`
   (control): dispatches that called `suite_run` anyway. Each one is a
   contaminated control dispatch. If there are many, `experiment_exclude`
   those tasks with the reason.
4. **Then the metrics**, per agent, arm against arm:
   `suite_tool_calls_mean` / `_median`, `client_turns_mean`,
   `client_tokens_in_mean` / `client_tokens_out_mean`, `wall_ms_mean` /
   `_median`, `outcome_first_pass_mean` (stage passed, no failed validation,
   no re-dispatch). Inner calls made inside `suite_run` scripts are not in
   `suite_tool_calls`. That is the point: those are calls the model did not
   have to issue. `dispatch_metrics_list` shows them as `inner_tool_calls`.

The report computes no lift and no comparison. A weaker model doing worse
under code mode is a valid result to record for that agent, not a failure of
the experiment.

### The exclusion rule for an agent that produces no data

Decide this at each read, for each cohort agent:

- **No dispatches.** After 14 days, or once every other enrolled agent has
  reached `min_subjects` in both arms, an agent with `n: 0` in both arms is
  reported as "enrolled, produced no data", with the reason (offline,
  received no dispatches, could not see the bundle). It has no assigned tasks,
  so there is nothing to exclude, and it is not dropped from the canvas.
- **Dispatches but nothing attributable.** An agent whose `attribution_pct`
  is under 50, or whose arms are all `stage_row` with `suite_tool_calls` at 0
  across `n ≥ min_subjects`, has unmeasurable server-side calls. Report its
  `client_*` metrics only, if it has any, and say why. If it has neither,
  exclude its tasks with `experiment_exclude`, give the reason, and keep the
  row in the canvas.
- **Moore specifically.** `ack_pct: 0.0` is expected and is NOT a reason to
  exclude. Exclude Moore only under the two rules above.

## Step 7: the canvas

Publish a canvas from `code_mode_report`, attached to task `01a114a8` with
`task_attach_canvas`. Give it one table per agent (arm, n, tasks, each
metric's value and n, adoption and violations) and a coverage line per agent.
Put the dispatches per cell in the heading. Re-publish it with
`canvas_patch` as data accrues. Do not create a new canvas each time.

## Rollback

- Stop assigning NEW tasks: `experiment_stop` with feedback. Assigned tasks
  keep their arm and their directive, by design.
- Remove the directive entirely: stop the experiment, then untick
  `code_mode` in Control Center. A treatment task still in flight then sees a
  directive for a tool it cannot call. Prefer letting in-flight tasks finish.
- The usage hook: remove the two `hooks` entries. It never blocks a session,
  because every error path exits 0.
