defmodule Platform.Responsibilities.Handlers.SecurityCodeAudit do
  @moduledoc """
  Placeholder handler for `security.code_audit` (task `019f3e8e-4406`
  stage 1 — see ADR-0043).

  Registration-only stub. The actual scanner body — a YAML rubric of
  regex + AST probes applied to `apps/platform/lib/**/*.ex` — lands in
  stage 4 (`Platform.Security.Scanners.CodeAudit.run_scan/2`). The row
  exists here so `Platform.Roles.assignee_for/1` is resolvable before
  the runtime is wired.

  ## Spec

    * `key` — `"security.code_audit"`
    * `feature` — `"security"`
    * `trigger_kind` — `event_topic` bound to
      `platform.security.sweeper_only` — the same null topic used by
      every scanner in the Security Guard bundle; see ADR-0043.
    * `scope` — `per_org`
    * `context_provided` — `[]`
    * `cost_profile` — `low_freq_capable`
    * `cadence` (metadata) — `"0 3 * * 1"` (weekly Monday 03:00 UTC)
    * `default_prompt_template` — `"security.code_audit.v1"` (LLM-facing
      enrichment layer; deterministic scanner still produces the raw
      finding, template refines summary + priority + remediation. See
      `Platform.Security.LlmEnrichment` in stage 3.)
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  @key "security.code_audit"
  @feature "security"
  @topic "platform.security.sweeper_only"
  @template_slug "security.code_audit.v1"
  @runtime_task "019f3e8e-4406"

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical Sweeper-only topic — no publisher ever broadcasts to it."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "event_topic",
        trigger_config: %{"topic" => @topic},
        scope: "per_org",
        context_provided: [],
        output_contract: %{
          "findings" => "list[map]"
        },
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.security",
          "role" => "security_guard",
          "status" => "placeholder",
          "executor" => "platform.security.sweeper",
          "cadence" => "0 3 * * 1"
        }
      }
    ]
  end

  @impl true
  def gather_context(_responsibility, _ctx) do
    {:ok, %{}}
  end

  @impl true
  def handle_output(responsibility, output) do
    handle_output(responsibility, output, %{})
  end

  @impl true
  def handle_output(_responsibility, _output, _trigger_meta) do
    Logger.warning(
      "[security.code_audit] placeholder handler — Router should never fire " <>
        "this row (null topic). Sweeper runtime lands in task #{@runtime_task} stage 2+."
    )

    :ok
  end
end
