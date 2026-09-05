defmodule Platform.Meetings.AgentDelayReason do
  @moduledoc """
  Why an agent's turn is taking a while — one short, honest clause, or
  `nil` (task 01a06e07 stage 2).

  ## Inference, not emission

  Every cause below is derived from a fact the system already tracks
  somewhere. Nothing here asks an agent to report its own state, and
  nothing here is a new outbound signal — a state an agent has to
  remember to emit is a state it will forget to clear, which is the
  reasoning `Platform.Meetings.AgentActivity`'s moduledoc already applies
  to `:heard`.

  ## `for_agent/1` is pure — the gathering happens elsewhere

  `for_agent/1` takes a plain map of ALREADY-GATHERED facts and makes no
  database call, no ETS read and no presence check. That split matters
  because the five facts are not equally cheap to gather:

    * `:reply_budget_exhausted?` / `:reply_budget_reset_in_s` and
      `:agent_chain_too_deep?` are cheap. `say/4`'s two refusals
      (`:reply_budget_exhausted`, `:agent_chain_too_deep`) are returned to
      the AGENT'S OWN tool call and broadcast nowhere — nothing else is
      ever told a say was refused. So these facts cannot be listened for;
      they have to be read back from the same persisted ledger `say/4`
      itself gates on. `Platform.Meetings.reply_budget_exhausted?/2`,
      `Platform.Meetings.reply_budget_reset_in_s/2` and
      `Platform.Meetings.agent_chain_too_deep?/1` are that read-back —
      each a synchronous `Platform.Meetings.SayRegistry` ETS query, no DB.

    * `:runtime_offline?` — `Platform.Meetings.runtime_offline?/1` is the
      read-back: one `Repo.get/2` by primary key
      (`Federation.get_runtime_for_agent/1`) plus
      `Platform.Federation.RuntimePresence.online?/1` (in-memory). Ordinary
      per-render cost, the same shape as work `AgentActivity.hydrate/1`
      already does at mount.

    * `:no_voice_worker?` is the one that is NOT cheap. Determining it
      needs `Meetings.resolve_voice_target/1`, which is a DB read
      (`Federation.runtimes_for_agent/1`) plus a presence read. A render
      loop calling that once per agent per second is unbounded work
      driven by a clock. `Platform.Meetings.VoiceSeatCache.seated?/1` is
      the bound this stage ships for it — see that module's moduledoc.
      Whatever gathers facts for `for_agent/1` MUST go through
      `VoiceSeatCache.seated?/1`, never call `resolve_voice_target/1`
      directly on a per-render path.

  This module deliberately does not wrap those four sources into one
  "gather" function. Which facts are worth computing on a given tick
  (for example: skip the voice-worker cache lookup entirely for an agent
  that is not even in a working state yet) is a decision about the
  render loop, and the render loop is stage 3's.

  ## Priority and timing

  A SPECIFIC (non-default) cause is checked first, in the order below,
  and shows immediately — no age threshold. The default clause,
  `"still running a tool"`, is different: it names nothing specific, so
  showing it right away would caption every ordinary two-second tool
  call as a delay. It only appears once `:age_s` has reached
  `default_shows_after_s/0`.

  When no fact is true and the agent has not yet reached that age,
  `for_agent/1` returns `nil` — there is nothing honest to say yet.
  """

  @typedoc """
  The facts `for_agent/1` reads. Every key is optional; an absent key
  reads the same as its default below (`false` for the `?`-suffixed
  keys, `0` for the two numeric ones) — a caller that has not gathered a
  fact simply does not claim it is true.
  """
  @type facts :: %{
          optional(:reply_budget_exhausted?) => boolean(),
          optional(:reply_budget_reset_in_s) => non_neg_integer(),
          optional(:no_voice_worker?) => boolean(),
          optional(:agent_chain_too_deep?) => boolean(),
          optional(:runtime_offline?) => boolean(),
          optional(:age_s) => integer()
        }

  # The default clause is withheld until the agent has been in its
  # current working state at least this long, so a two-second tool call
  # is never captioned. Chosen, not measured: if stage 3 finds this too
  # eager or too slow against a real meeting, this is the dial.
  @default_shows_after_s 10

  @doc "Seconds a working agent must age before the default clause shows."
  @spec default_shows_after_s() :: pos_integer()
  def default_shows_after_s, do: @default_shows_after_s

  @doc """
  The delay reason for one agent, or `nil`.

  Pure — see the moduledoc. Checks each specific cause in order and
  returns its clause on the first one that is true; falls through to the
  default clause once `facts[:age_s]` reaches `default_shows_after_s/0`;
  otherwise `nil`.
  """
  @spec for_agent(facts()) :: String.t() | nil
  def for_agent(facts) when is_map(facts) do
    cond do
      Map.get(facts, :reply_budget_exhausted?, false) ->
        "reply budget resets in #{Map.get(facts, :reply_budget_reset_in_s, 0)}s"

      Map.get(facts, :no_voice_worker?, false) ->
        "no voice worker in this room"

      Map.get(facts, :agent_chain_too_deep?, false) ->
        "waiting for a human to speak"

      Map.get(facts, :runtime_offline?, false) ->
        "agent went offline"

      Map.get(facts, :age_s, 0) >= @default_shows_after_s ->
        "still running a tool"

      true ->
        nil
    end
  end
end
