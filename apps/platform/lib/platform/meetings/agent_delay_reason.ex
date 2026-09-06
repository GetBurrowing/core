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

  # The clause that names nothing. Held apart from the four specific ones
  # so `specific_for_agent/1` can be stated as "everything except this"
  # rather than by repeating the list — see that function.
  @default_clause "still running a tool"

  @doc "Seconds a working agent must age before the default clause shows."
  @spec default_shows_after_s() :: pos_integer()
  def default_shows_after_s, do: @default_shows_after_s

  @doc "The clause shown when no specific cause holds and the agent has aged."
  @spec default_clause() :: String.t()
  def default_clause, do: @default_clause

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
      clause = reply_budget_clause(facts) ->
        clause

      clause = no_voice_worker_clause(facts) ->
        clause

      clause = chain_or_offline_clause(facts) ->
        clause

      Map.get(facts, :age_s, 0) >= @default_shows_after_s ->
        @default_clause

      true ->
        nil
    end
  end

  @doc """
  The causes that may be PROMOTED TO A STATE — `nil` for everything else
  (task `01a07400` stage 2, narrowed in stage 3).

  Same order and same clauses as `for_agent/1`, minus two of its five.

  ## What it leaves out, and why each is left out

  **`"still running a tool"`** — the default clause names nothing. It is
  what `for_agent/1` says when it has found no cause at all and the agent
  has merely been working a while. An agent that is simply taking its time
  is working, not blocked, so it stays `:computing`/`:thinking` and keeps
  the default clause as the decoration it already is on the rail.
  Promoting it would put "Delayed" on every ordinary turn past ten
  seconds, which is the always-on badge shape canvas `01a05b11-54ff`
  removed `:listening` for, under a different word.

  **`:no_voice_worker?`** — removed from this set in stage 3, and for a
  stronger reason than the default clause's: not "usually too eager" but
  "wrong in every reachable configuration".

  `AgentActivity.apply_delays/2` only promotes an agent whose state is in
  `AgentActivity.delayable_states/0`, and that list is
  `[:computing, :typing, :thinking, :composing]`. **`:speaking` is not in
  it** — deliberately, because audio going out right now is the one state
  that cannot simultaneously be stuck. So a `:no_voice_worker?` promotion
  can only ever fire on an agent that is *not* speaking; and a missing
  voice worker does not hold up thinking, composing, computing or typing.
  There is therefore no configuration in which "Delayed · no voice worker
  in this room" is the true reading: it fires exactly when the agent is
  demonstrably working on something a voice worker is not needed for.

  The measured symptom was an agent with a connected brain runtime and a
  registered voice-capable runtime that is merely OFFLINE — the ordinary
  state of any deployment whose voice worker has dropped — rendering its
  `:composing` turn as `Delayed · no voice worker in this room`, losing
  the working colour, losing `animate-pulse`, and gaining a second line.

  This is NOT a timing problem and must not be "fixed" with an age
  threshold: the clause is not too early, it is not a delay at all, and a
  timer would only make a false statement arrive later.

  ### The fact itself is not deleted — only its promotion

  `no_voice_worker?` remains a clause in `for_agent/1`, in its original
  position and with no age threshold, so it still renders as the trailing
  note it has always been. When an agent genuinely is trying to speak and
  no worker is seated, `"no voice worker in this room"` is the most useful
  sentence on the screen; what it must not do is overwrite the true state
  word with a false one.

  `for_agent/1` is unchanged in behaviour and remains the rail's reader.
  """
  @spec specific_for_agent(facts()) :: String.t() | nil
  def specific_for_agent(facts) when is_map(facts) do
    cond do
      clause = reply_budget_clause(facts) -> clause
      clause = chain_or_offline_clause(facts) -> clause
      true -> nil
    end
  end

  # ── The clauses, held apart so the two readers can differ by exactly
  # ── which ones they consult, rather than by a duplicated `cond`.

  defp reply_budget_clause(facts) do
    if Map.get(facts, :reply_budget_exhausted?, false) do
      "reply budget resets in #{Map.get(facts, :reply_budget_reset_in_s, 0)}s"
    end
  end

  # Consulted by `for_agent/1` only — see `specific_for_agent/1`'s @doc for
  # why this one may not become a state.
  defp no_voice_worker_clause(facts) do
    if Map.get(facts, :no_voice_worker?, false), do: "no voice worker in this room"
  end

  defp chain_or_offline_clause(facts) do
    cond do
      Map.get(facts, :agent_chain_too_deep?, false) ->
        "waiting for a human to speak"

      Map.get(facts, :runtime_offline?, false) ->
        "agent went offline"

      true ->
        nil
    end
  end
end
