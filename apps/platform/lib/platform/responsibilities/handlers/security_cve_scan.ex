defmodule Platform.Responsibilities.Handlers.SecurityCveScan do
  @moduledoc """
  Placeholder handler for `security.cve_scan` (task `019f3e8e-4406`
  stage 1 — see ADR-0043).

  Registration-only stub. The actual scanner body lands in stage 3
  (`Platform.Security.Scanners.CveScan.run_scan/2`); the row exists here
  so `Platform.Roles.assignee_for/1` is resolvable and Control Center →
  Roles surfaces the Security Guard bundle before the runtime is wired.

  ## Spec

    * `key` — `"security.cve_scan"`
    * `feature` — `"security"`
    * `trigger_kind` — `event_topic` bound to the null topic
      `platform.security.sweeper_only`. No publisher ever broadcasts
      to this topic; the Router's subscription is a genuine no-op.
      The Sweeper (task `019f3e8e-4406` stage 2 — see
      `Platform.Security.Sweeper`) drives the actual cadence.
    * `scope` — `per_org`
    * `context_provided` — `[]` (scanner runtime gathers its own
      lockfile / manifest context)
    * `cost_profile` — `low_freq_capable`
    * `default_prompt_template` — `"security.cve_scan.v1"` (LLM-facing
      enrichment layer; deterministic scanner still produces the raw
      finding, template refines summary + priority + remediation. See
      `Platform.Security.LlmEnrichment` in stage 3.)

  ## Metadata

    * `owner` — `"platform.security"`
    * `role` — `"security_guard"`
    * `status` — `"placeholder"` (operators grep this to find rows
      whose runtime hasn't landed yet)
    * `executor` — `"platform.security.sweeper"` (the runtime the
      Sweeper reads to figure out which scanner module to invoke)
    * `cadence` — `"0 3 * * 1"` (weekly Monday 03:00 UTC) — the
      Sweeper parses this via `Platform.Responsibilities.Cron` to
      decide when to fire.

  ## Why the null-topic trick

  See ADR-0043. Router's cron path routes through LLM or
  AgentResponder — neither fits a deterministic filesystem + OSV.dev
  scan. Registering with `trigger_kind: "cron"` would burn an
  unnecessary LLM call weekly per key. Registering with the null
  event_topic keeps admin-UI + assignee_for/1 resolvable while making
  the Router path a genuine no-op.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  @key "security.cve_scan"
  @feature "security"
  @topic "platform.security.sweeper_only"
  @template_slug "security.cve_scan.v1"
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
      "[security.cve_scan] placeholder handler — Router should never fire " <>
        "this row (null topic). Sweeper runtime lands in task #{@runtime_task} stage 2+."
    )

    :ok
  end
end
