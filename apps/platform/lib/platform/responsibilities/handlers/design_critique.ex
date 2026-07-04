defmodule Platform.Responsibilities.Handlers.DesignCritique do
  @moduledoc """
  Placeholder handler for `design.critique` (task 019f2455 stage 1).

  Registration-only stub that fills out one of the Designer role
  bundle's three responsibilities so `Platform.Roles.Seeds` no longer
  points at a key with no matching `responsibilities` row.

  ## Spec

    * `key` — `"design.critique"`
    * `feature` — `"design"`
    * `trigger_kind` — `chat_pattern` with `regex: "@vega\\s+(critique|review)\\b"`
      (case-insensitive; designers invoke the responsibility by mentioning
      Vega with a critique/review verb)
    * `scope` — `per_space`
    * `context_provided` — `["canvas_snapshot", "grounding_notes"]`
    * `cost_profile` — `low_freq_capable`

  ## Output contract

  Declared as a map-of-strings to satisfy the M1 schema invariant
  (`Responsibility.changeset/2` rejects non-string values in the JSONB
  `output_contract` column). The prompt template lands the actual JSON
  shape; here we only carry the top-level key name.

  ## Provider callback stubs

  `gather_context/2` returns `:canvas_snapshot` + `:grounding_notes`
  slots marked `missing?: true` — the runtime that materialises canvas
  snapshots for design review has not been wired yet, and this handler
  exists to fill the bundle roster (task 019f2455) not to fire live.

  `handle_output/2` and `handle_output/3` log a placeholder warning
  and return `:ok`. Rowan/Marlowe iterate the prompt template content
  live via `prompt_template_update` MCP after the seed migration lands
  — this handler doesn't gate that iteration.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  @key "design.critique"
  @feature "design"
  @template_slug "design.critique.v1"

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
          "regex" => "(?i)@vega\\s+(critique|review)\\b"
        },
        scope: "per_space",
        context_provided: ["canvas_snapshot", "grounding_notes"],
        output_contract: %{
          "issues" => "list[map]"
        },
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.design",
          "status" => "placeholder",
          "role" => "designer"
        }
      }
    ]
  end

  @impl true
  def gather_context(_responsibility, _ctx) do
    {:ok,
     %{
       canvas_snapshot: %{missing?: true, note: "runtime not yet implemented"},
       grounding_notes: %{missing?: true, note: "runtime not yet implemented"}
     }}
  end

  @impl true
  def handle_output(responsibility, output) do
    handle_output(responsibility, output, %{})
  end

  @impl true
  def handle_output(_responsibility, _output, _trigger_meta) do
    Logger.warning(
      "[design.critique] placeholder handler — dispatch not implemented; " <>
        "seed carries prompt template #{@template_slug}"
    )

    :ok
  end
end
