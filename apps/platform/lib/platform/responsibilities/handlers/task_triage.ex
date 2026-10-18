defmodule Platform.Responsibilities.Handlers.TaskTriage do
  @moduledoc """
  Placeholder handler for `tasks.triage` (task 019f2455 stage 4).

  Registration-only stub that fills out one of the Triage Officer role
  bundle's three responsibilities so `Platform.Roles.Seeds` no longer
  points at a key with no matching `responsibilities` row.

  ## Spec

    * `key` — `"tasks.triage"`
    * `feature` — `"tasks"`
    * `trigger_kind` — `cron` with `expression: "0 9 * * 1-5"` (09:00 UTC weekdays)
    * `scope` — `per_project`
    * `context_provided` — `["org_identity"]`
    * `cost_profile` — `high_freq_low_cost`

  ## Output contract

  The prompt template returns
  `%{"triage" => [%{"task_id" => ..., "suggested_priority" => ..., "reason" => ...}, ...]}`.
  The `output_contract` map here only carries top-level keys because the
  M1 schema rejects non-string values in the JSONB column.

  ## DECLARED INERT — `metadata["dispatch"] == "inert"`

  This key is registered but deliberately **not dispatchable** (task
  `01a0b4d1`, the RETIRE path). Until then the weekday cron fired it at
  09:00 UTC, the assignee answered, and `handle_output/3` threw the
  answer away with a placeholder log line — a paid model round-trip per
  weekday with nothing consuming it.

  `Platform.Responsibilities.Router.fire_trigger/3` refuses any row
  whose `metadata["dispatch"]` is `"inert"`, before assignee
  resolution, returning `{:ok, :placeholder}` and logging
  `[ResponsibilityRouter] placeholder responsibility=tasks.triage`.
  The row keeps its cron `trigger_kind` and expression, so it still
  sits in the Router's cron bucket and still computes next-fire times;
  the veto is at fire time, not in the due-list. It is NOT unscheduled.

  The `responsibilities` row, its role mapping and the `tasks.triage.v1`
  prompt template all stay, so re-enabling is a one-line code change and
  not a re-seed.

  ### Why `dispatch` and not `status`

  `"status" => "placeholder"` stays, but it is NOT a dispatch veto:
  eleven rows carry it and several of them fire legitimately. See
  `Handlers.MeetingAttendanceFollowup`'s moduledoc and the comment above
  `Router.dispatch_inert?/1` for that argument; this row follows the same
  two-field convention.

  ### Why `metadata` and not `enabled: false`

  `Platform.Responsibilities.@upsert_replace_fields` deliberately
  EXCLUDES `enabled` — operator territory, preserved across upserts so
  admin-UI toggles survive redeploys. A code-side `enabled: false` here
  would be a no-op against the row already in production. `metadata` IS
  in the replace list, so this declaration reaches every install on its
  next boot's `Registry` register pass, with no migration.

  ### How to re-enable

  Delete `"dispatch" => "inert"` from `register/0` below, in the same
  edit that implements `handle_output/3` for real. Not a config toggle:
  the marker exists because the handler below discards its input.

  ## Callback stubs

  `gather_context/2` returns an `:org_identity` slot marked `missing?:
  true` — the runtime that materialises project task lists for triage
  has not been wired yet.

  `handle_output/2` and `handle_output/3` log a placeholder warning and
  return `:ok`. The operator and designer iterate the prompt template content live via
  `prompt_template_update` MCP after the seed migration lands — this
  handler doesn't gate that iteration.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  @key "tasks.triage"
  @feature "tasks"
  @template_slug "tasks.triage.v1"

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "cron",
        # 09:00 UTC weekdays — the Triage Officer sweeps the backlog
        # every weekday morning to propose a priority pass before the
        # day's standups start.
        trigger_config: %{"expression" => "0 9 * * 1-5"},
        scope: "per_project",
        context_provided: ["org_identity"],
        output_contract: %{
          "triage" => "list[map]"
        },
        default_prompt_template: @template_slug,
        cost_profile: "high_freq_low_cost",
        # `dispatch: "inert"` has exactly one reader,
        # `Router.dispatch_inert?/1`, and is the only thing that stops
        # this row firing (task 01a0b4d1). `status: "placeholder"` is the
        # operator/reporting marker and is NOT a dispatch veto. See the
        # moduledoc for why this is metadata and not `enabled: false`.
        metadata: %{
          "owner" => "platform.tasks",
          "status" => "placeholder",
          "role" => "triage_officer",
          "dispatch" => "inert"
        }
      }
    ]
  end

  @impl true
  def gather_context(_responsibility, _ctx) do
    {:ok,
     %{
       org_identity: %{missing?: true, note: "runtime not yet implemented"}
     }}
  end

  @impl true
  def handle_output(responsibility, output) do
    handle_output(responsibility, output, %{})
  end

  @impl true
  def handle_output(_responsibility, _output, _trigger_meta) do
    Logger.warning(
      "[tasks.triage] placeholder handler — dispatch not implemented; " <>
        "seed carries prompt template #{@template_slug}"
    )

    :ok
  end
end
