defmodule Platform.Chat.MentionIdentity do
  @moduledoc """
  The single rule for which bracketed `@[…]` tokens name an agent.

  An agent is named by a bracketed token equal (case-insensitively) to its
  `name` OR its `slug`. Two call sites need that answer and must never
  disagree:

    * the summon path, `Platform.Chat.mentioned_summonable_agents/2`, which
      adds the named agent to the space; and
    * the router, `Platform.Chat.AttentionRouter.mentioned?/3`, which decides
      whether the message is delivered to it.

  They used to carry their own copies of the rule. The summon path matched
  slug or name while the router matched only the participant's cached
  display name, so a slug token summoned the agent and was then never
  delivered to it (task 01a0fdfe). Neither module re-implements the match;
  both call `agent_named?/2`.

  Matching is exact against bracketed tokens only. The router's unbracketed
  legacy `@name` zone is substring-matched, and a slug there would make a slug
  that prefixes another slug (`x-agent` inside `@x-agent-2`) a false mention,
  so slugs are deliberately not offered to it.
  """

  alias Platform.Agents.Agent

  @doc """
  The downcased, non-blank, de-duplicated identity keys of `agent`: its
  `name` and its `slug`.
  """
  @spec agent_keys(Agent.t()) :: [String.t()]
  def agent_keys(%Agent{name: name, slug: slug}) do
    [name, slug]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  @doc """
  True iff any of `agent`'s keys is one of `bracketed_tokens`.

  `bracketed_tokens` must already be downcased, as returned by
  `Platform.Chat.AttentionRouter.extract_bracketed_tokens/1` called on
  downcased content. Membership is exact: a token that merely starts with a
  key does not match.
  """
  @spec agent_named?(Agent.t(), [String.t()]) :: boolean()
  def agent_named?(%Agent{} = agent, bracketed_tokens) when is_list(bracketed_tokens) do
    Enum.any?(agent_keys(agent), &(&1 in bracketed_tokens))
  end

  def agent_named?(_agent, _tokens), do: false
end
