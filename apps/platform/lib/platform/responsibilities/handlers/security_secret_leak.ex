defmodule Platform.Responsibilities.Handlers.SecuritySecretLeak do
  @moduledoc """
  Placeholder handler for `security.secret_leak` (task `019f3e8e-4406`
  stage 1 — see ADR-0043).

  Registration-only stub. The actual scanner body — a gitleaks-shaped
  regex library applied to the working tree (and optionally git history)
  plus a companion pre-push git hook installer — lands in stage 5
  (`Platform.Security.Scanners.SecretLeak.run_scan/2`). The row exists
  here so `Platform.Roles.assignee_for/1` is resolvable before the
  runtime is wired.

  ## Spec

    * `key` — `"security.secret_leak"`
    * `feature` — `"security"`
    * `trigger_kind` — `event_topic` bound to
      `platform.security.sweeper_only`; see ADR-0043.
    * `scope` — `per_org`
    * `context_provided` — `[]`
    * `cost_profile` — `low_freq_capable`
    * `cadence` (metadata) — `"0 4 * * *"` (daily 04:00 UTC — this is
      the only Security Guard scan that runs daily; the other three
      are weekly because their signal changes on a slower timescale)
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  @key "security.secret_leak"
  @feature "security"
  @topic "platform.security.sweeper_only"
  @runtime_task "019f3e8e-4406"

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical Sweeper-only topic — no publisher ever broadcasts to it."
  @spec topic() :: String.t()
  def topic, do: @topic

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
        default_prompt_template: nil,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.security",
          "role" => "security_guard",
          "status" => "placeholder",
          "executor" => "platform.security.sweeper",
          "cadence" => "0 4 * * *"
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
      "[security.secret_leak] placeholder handler — Router should never fire " <>
        "this row (null topic). Sweeper runtime lands in task #{@runtime_task} stage 2+."
    )

    :ok
  end
end
