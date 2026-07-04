defmodule Platform.Responsibilities.Handlers.TaskWeeklyReview do
  @moduledoc """
  Placeholder handler for `tasks.weekly_review` (task 019f2455 stage 4).

  Registration-only stub that fills out one of the Triage Officer role
  bundle's three responsibilities so `Platform.Roles.Seeds` no longer
  points at a key with no matching `responsibilities` row.

  ## Spec

    * `key` — `"tasks.weekly_review"`
    * `feature` — `"tasks"`
    * `trigger_kind` — `cron` with `expression: "0 16 * * 5"` (16:00 UTC Fridays)
    * `scope` — `per_project`
    * `context_provided` — `["org_identity", "recent_journal"]`
    * `cost_profile` — `low_freq_capable`

  ## Output contract

  The prompt template returns
  `%{"review" => "<one paragraph>", "followups" => ["<optional>", ...]}`.
  The `output_contract` map here only carries top-level keys because
  the M1 schema rejects non-string values in the JSONB column.
  `followups` is declared with a trailing `?` to flag optionality.

  ## Callback stubs

  `gather_context/2` returns `:org_identity` + `:recent_journal` slots
  marked `missing?: true` — the runtime that materialises the last
  seven days of touched tasks alongside the journal has not been wired
  yet, and this handler exists to fill the bundle roster (task
  019f2455) not to fire live.

  `handle_output/2` and `handle_output/3` log a placeholder warning
  and return `:ok`. Rowan/Marlowe iterate the prompt template content
  live via `prompt_template_update` MCP after the seed migration lands
  — this handler doesn't gate that iteration.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  @key "tasks.weekly_review"
  @feature "tasks"
  @template_slug "tasks.weekly_review.v1"

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
        # 16:00 UTC Fridays — the Triage Officer writes a short weekly
        # digest at the end of the working week (roughly late morning
        # US Pacific, late afternoon UK) so the project has a written
        # record of what shipped + what slipped before the weekend.
        trigger_config: %{"expression" => "0 16 * * 5"},
        scope: "per_project",
        context_provided: ["org_identity", "recent_journal"],
        output_contract: %{
          "review" => "string",
          "followups" => "list[string]?"
        },
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
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
       org_identity: %{missing?: true, note: "runtime not yet implemented"},
       recent_journal: %{missing?: true, note: "runtime not yet implemented"}
     }}
  end

  @impl true
  def handle_output(responsibility, output) do
    handle_output(responsibility, output, %{})
  end

  @impl true
  def handle_output(_responsibility, _output, _trigger_meta) do
    Logger.warning(
      "[tasks.weekly_review] placeholder handler — dispatch not implemented; " <>
        "seed carries prompt template #{@template_slug}"
    )

    :ok
  end
end
