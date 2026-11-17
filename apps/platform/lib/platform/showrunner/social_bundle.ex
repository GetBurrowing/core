defmodule Platform.Showrunner.SocialBundle do
  @moduledoc """
  Can the showrunner agent actually call its `social_*` tools? Task 01a1eaf6
  stage 4.

  Core never names Social (ADR 0055): every Social action is the AGENT's,
  through the MCP tools of the `social` bundle. Before `showrunner.post_show`
  or `showrunner.retro` dispatches, core asks this module whether the agent's
  runtime can reach that bundle, by its string name only.

  ## Effective tools, not the profile

  The answer is `Platform.Access.Tools.effective_tools/1` over the agent's
  runtime (`Platform.Federation.get_runtime/1` on `agent.runtime_id`), not the
  stored tool profile. A profile can list `social` while an owner cap removes
  every tool in it; a profile-only check would then dispatch post_show to an
  agent that cannot call `social_draft_create`. This is the same rule goals
  intake applies to a lead's tools.

  `social` is present when at least one effective tool carries
  `bundle: "social"`. In a without-modules build the bundle contributes no
  tools at all, so it reads as absent, which is the answer we want there.
  """

  alias Platform.Access.Tools
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat.Canvas
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Showrunner.Board
  alias Platform.Showrunner.Episode

  @bundle "social"

  @missing_item %{
    id: "social-missing",
    question: "The showrunner can't reach Social: add the social tool bundle to its runtime",
    options: ["Added"]
  }

  @typedoc "Why the bundle is unreachable, when it is."
  @type absence :: :no_agent | :no_runtime | :not_effective

  @doc "The bundle name checked (`\"social\"`)."
  @spec bundle() :: String.t()
  def bundle, do: @bundle

  @doc "The Needs-you item a fire raises when the bundle is unreachable."
  @spec missing_item() :: map()
  def missing_item, do: @missing_item

  @doc """
  The guard post_show and retro run before dispatching: `:ok` when the acting
  agent (`ctx.agent_id`) can reach the bundle; otherwise ONE Needs-you item
  (`missing_item/0`, raised once however often this runs) and
  `{:parked, reason}`. The caller then returns `{:handled, _}` and the Router
  dispatches nothing. Never raises.
  """
  @spec guard(Board.ctx(), Canvas.t(), map(), Episode.t()) :: :ok | {:parked, absence()}
  def guard(ctx, %Canvas{} = canvas, document, %Episode{} = episode) do
    case status(Repo.get(Agent, ctx.agent_id)) do
      :present ->
        :ok

      {:absent, reason} ->
        Board.raise_needs_you(ctx, canvas, document, episode, @missing_item,
          detail: "Post and retro wait here until it is added (#{reason})."
        )

        {:parked, reason}
    end
  rescue
    _ -> {:parked, :not_effective}
  end

  @doc "True when `agent`'s runtime can call at least one `social` tool."
  @spec present?(Agent.t() | map() | nil) :: boolean()
  def present?(agent), do: status(agent) == :present

  @doc """
  `:present`, or `{:absent, reason}` (`:no_agent`, `:no_runtime`,
  `:not_effective`). Never raises: a failure reads as absent.
  """
  @spec status(Agent.t() | map() | nil) :: :present | {:absent, absence()}
  def status(%{runtime_id: runtime_id}) when is_binary(runtime_id) do
    case Federation.get_runtime(runtime_id) do
      %AgentRuntime{} = runtime ->
        if Enum.any?(Tools.effective_tools(runtime), &(Map.get(&1, :bundle) == @bundle)),
          do: :present,
          else: {:absent, :not_effective}

      nil ->
        {:absent, :no_runtime}
    end
  rescue
    _ -> {:absent, :not_effective}
  end

  def status(%{runtime_id: nil}), do: {:absent, :no_runtime}
  def status(_agent), do: {:absent, :no_agent}
end
