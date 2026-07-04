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

  ## Callback stubs

  `gather_context/2` returns an `:org_identity` slot marked `missing?:
  true` — the runtime that materialises project task lists for triage
  has not been wired yet, and this handler exists to fill the bundle
  roster (task 019f2455) not to fire live.

  `handle_output/2` and `handle_output/3` log a placeholder warning and
  return `:ok`. Rowan/Marlowe iterate the prompt template content live via
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
        metadata: %{
          "owner" => "platform.tasks",
          "status" => "placeholder",
          "role" => "triage_officer"
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
