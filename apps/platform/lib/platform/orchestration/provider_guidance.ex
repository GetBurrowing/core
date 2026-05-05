defmodule Platform.Orchestration.ProviderGuidance do
  @moduledoc """
  Provider-specific dispatch guidance.

  When a dispatch (planning, in_progress, in_review) is routed to an agent
  whose runtime is a Claude-Code MCP plugin, we tell the agent to handle the
  work in a fresh-context subagent. Other providers get an empty string —
  provider-specific fragments will be added as we learn what works.

  Detection order in `for_agent/2`:

    1. Federation handshake — `runtime.metadata["client_info"]["product"]`
       via `AgentRuntime.client_product/1`. `"claude_channel"` returns the
       Claude block; `"openclaw"` returns `""`.
    2. Model-name fallback — when `client_product/1` is `"unknown"` (older
       runtimes that haven't declared yet), check `agent.model_config["primary"]`
       against `~r/^claude/i`.
    3. Nil agent — `""` (back-compat for renderers that don't pass an agent).
  """

  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime

  @claude_subagent_guidance """
  ## For Claude Code agents (mandatory)

  Handle this task in a subagent with fresh context, **spawned as a background process**. Spawn it via the Agent tool — `general-purpose` is fine — with `run_in_background: true` so the parent conversation stays responsive while the subagent executes. Brief it with the full dispatch payload above, including the Organization Context section. Do NOT do this work in the parent conversation. The goals: (1) fresh context per task so the org-context discipline below isn't competing with whatever's already loaded, (2) audit clarity so the task lives in its own conversation tree, (3) parent responsiveness — the parent can keep handling other inbound messages or tasks while the subagent runs.

  The subagent should: read org context first, do the work, write to org memory on decisions, and report back a tight summary. The parent just spawns, then waits for the task-completion notification (do NOT poll, sleep, or proactively check progress — Claude Code notifies the parent automatically when the background agent finishes) and relays the result.\
  """

  @doc """
  Returns the dispatch guidance fragment to inject for the given agent.

  See module doc for detection order.
  """
  @spec for_agent(Agent.t() | nil, AgentRuntime.t() | nil) :: String.t()
  def for_agent(agent, runtime \\ nil)
  def for_agent(nil, _runtime), do: ""

  def for_agent(%Agent{} = agent, runtime) do
    case product_for(runtime) do
      "claude_channel" -> @claude_subagent_guidance
      "openclaw" -> ""
      "unknown" -> guidance_from_model(agent)
    end
  end

  def for_agent(_, _), do: ""

  @doc "Canonical Claude block — exposed for tests and template authoring."
  @spec claude_subagent_guidance() :: String.t()
  def claude_subagent_guidance, do: @claude_subagent_guidance

  defp product_for(%AgentRuntime{} = runtime), do: AgentRuntime.client_product(runtime)
  defp product_for(_), do: "unknown"

  defp guidance_from_model(%Agent{model_config: model_config}) when is_map(model_config) do
    primary = Map.get(model_config, "primary") || Map.get(model_config, :primary)

    if is_binary(primary) and Regex.match?(~r/^claude/i, primary) do
      @claude_subagent_guidance
    else
      ""
    end
  end

  defp guidance_from_model(_), do: ""
end
