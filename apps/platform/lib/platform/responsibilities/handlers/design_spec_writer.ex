defmodule Platform.Responsibilities.Handlers.DesignSpecWriter do
  @moduledoc """
  Placeholder handler for `design.spec_writer` (task 019f2455 stage 1).

  Registration-only stub that fills out one of the Designer role
  bundle's three responsibilities so `Platform.Roles.Seeds` no longer
  points at a key with no matching `responsibilities` row.

  ## Spec

    * `key` — `"design.spec_writer"`
    * `feature` — `"design"`
    * `trigger_kind` — `chat_pattern` with
      `regex: "(?i)@designer\\s+spec\\b"`, built by
      `Platform.Responsibilities.RoleTrigger.chat_regex/3` (case-insensitive;
      invoked by addressing the Designer ROLE with a "spec" verb). The token
      names the role rather than whoever currently holds it, because the role
      outlives its holder — an agent handle baked into a trigger outlives the
      person exactly once and then lies.
    * `scope` — `per_space`
    * `context_provided` — `["canvas_snapshot", "grounding_notes"]`
    * `cost_profile` — `low_freq_capable`

  ## Output contract

  The prompt template returns
  `%{"spec" => %{"components" => [...], "acceptance_criteria" => [...]}}`.
  The `output_contract` map here only carries top-level keys because the
  M1 schema rejects non-string values in the JSONB column.

  ## Callback stubs

  `gather_context/2` returns placeholder slots; `handle_output/*` logs a
  warning and returns `:ok`. Real runtime lands when a follow-up ticket
  materialises canvas snapshots for design dispatch — the seed here
  unblocks the role/bundle wiring right now.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Responsibilities.RoleTrigger

  @key "design.spec_writer"
  @feature "design"
  # Single source for the role key: feeds BOTH the trigger regex and the
  # metadata map below, so the trigger and the declared role cannot drift.
  @role "designer"
  @template_slug "design.spec_writer.v1"

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
          "regex" => RoleTrigger.chat_regex(@role, "spec")
        },
        scope: "per_space",
        context_provided: ["canvas_snapshot", "grounding_notes"],
        output_contract: %{
          "spec" => "map"
        },
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.design",
          "status" => "placeholder",
          "role" => @role
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
      "[design.spec_writer] placeholder handler — dispatch not implemented; " <>
        "seed carries prompt template #{@template_slug}"
    )

    :ok
  end
end
