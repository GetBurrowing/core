defmodule Platform.Responsibilities.Handlers.TaskUnblock do
  @moduledoc """
  Placeholder handler for `tasks.unblock` (task 019f2455 stage 4).

  Registration-only stub that fills out one of the Triage Officer role
  bundle's three responsibilities so `Platform.Roles.Seeds` no longer
  points at a key with no matching `responsibilities` row.

  ## Spec

    * `key` — `"tasks.unblock"`
    * `feature` — `"tasks"`
    * `trigger_kind` — `chat_pattern` with `regex: "(?i)\\b(blocked|blocker|stuck)\\b"`
      (case-insensitive; fires when someone mentions being blocked in
      chat so the Triage Officer can propose next steps)
    * `scope` — `per_space`
    * `context_provided` — `["org_identity"]`
    * `cost_profile` — `low_freq_capable`

  ## Output contract

  The prompt template returns
  `%{"suggestions" => ["<one concrete step>", ...]}`. The
  `output_contract` map here only carries top-level keys because the
  M1 schema rejects non-string values in the JSONB column.

  ## Callback stubs

  `gather_context/2` returns an `:org_identity` slot marked `missing?:
  true` — the runtime that materialises the triggering chat message
  alongside org identity has not been wired yet, and this handler
  exists to fill the bundle roster (task 019f2455) not to fire live.

  `handle_output/2` and `handle_output/3` log a placeholder warning and
  return `:ok`. The operator and designer iterate the prompt template content live via
  `prompt_template_update` MCP after the seed migration lands — this
  handler doesn't gate that iteration.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  @key "tasks.unblock"
  @feature "tasks"
  @template_slug "tasks.unblock.v1"

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
        trigger_kind: "chat_pattern",
        trigger_config: %{
          "regex" => "(?i)\\b(blocked|blocker|stuck)\\b"
        },
        scope: "per_space",
        context_provided: ["org_identity"],
        output_contract: %{
          "suggestions" => "list[string]"
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
      "[tasks.unblock] placeholder handler — dispatch not implemented; " <>
        "seed carries prompt template #{@template_slug}"
    )

    :ok
  end
end
