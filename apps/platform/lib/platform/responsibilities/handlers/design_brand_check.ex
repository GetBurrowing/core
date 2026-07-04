defmodule Platform.Responsibilities.Handlers.DesignBrandCheck do
  @moduledoc """
  Placeholder handler for `design.brand_check` (task 019f2455 stage 1).

  Registration-only stub that fills out one of the Designer role
  bundle's three responsibilities so `Platform.Roles.Seeds` no longer
  points at a key with no matching `responsibilities` row.

  ## Spec

    * `key` — `"design.brand_check"`
    * `feature` — `"design"`
    * `trigger_kind` — `chat_pattern` with `regex: "@vega\\s+brand\\b"`
      (case-insensitive; designers invoke by mentioning Vega with a
      "brand" verb)
    * `scope` — `per_space`
    * `context_provided` — `["canvas_snapshot", "brand_guidelines"]`
    * `cost_profile` — `low_freq_capable`

  ## Output contract

  The prompt template returns
  `%{"verdict" => "on_brand|drift|off_brand", "reasons" => [...], "fixes" => [...]}`.
  The `output_contract` map here only carries top-level key type names
  because the M1 schema rejects non-string values in the JSONB column.

  ## Callback stubs

  `gather_context/2` returns placeholder slots; `handle_output/*` logs a
  warning and returns `:ok`. Real runtime lands when a follow-up ticket
  materialises canvas snapshots + brand-guideline grounding for the
  design dispatch surface — the seed here unblocks the role/bundle
  wiring right now.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  @key "design.brand_check"
  @feature "design"
  @template_slug "design.brand_check.v1"

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
          "regex" => "(?i)@vega\\s+brand\\b"
        },
        scope: "per_space",
        context_provided: ["canvas_snapshot", "brand_guidelines"],
        output_contract: %{
          "verdict" => "string",
          "reasons" => "list[string]",
          "fixes" => "list[string]"
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
       brand_guidelines: %{missing?: true, note: "runtime not yet implemented"}
     }}
  end

  @impl true
  def handle_output(responsibility, output) do
    handle_output(responsibility, output, %{})
  end

  @impl true
  def handle_output(_responsibility, _output, _trigger_meta) do
    Logger.warning(
      "[design.brand_check] placeholder handler — dispatch not implemented; " <>
        "seed carries prompt template #{@template_slug}"
    )

    :ok
  end
end
