defmodule Platform.Meetings.AgentActivity.Delayed do
  @moduledoc """
  The `:delayed` state — and the reason it is carrying (task `01a07400`
  stage 2).

  ## A reason-less `:delayed` is not representable

  This module exists so that the sentence "the agent is delayed" cannot be
  said without finishing it. `:delayed` is not an atom any producer in this
  codebase may hand around: the ONLY value the resolution path accepts at
  the delayed layer is a `%Delayed{}`, and a `%Delayed{}` cannot be built
  without a non-blank reason. Three barriers, deliberately independent, so
  that removing any one of them fails a test rather than quietly widening
  the type:

    1. `@enforce_keys [:reason]` — `%Delayed{}` does not compile, and
       `struct!(Delayed, %{})` raises at runtime.
    2. `new/1` refuses `nil`, a non-binary, and a blank or whitespace-only
       string with `{:error, :reason_required}`. It is the only
       constructor any caller here uses.
    3. `valid?/1` is re-checked at the point of use
       (`Platform.Meetings.AgentActivity.apply_delays/2`), so a struct
       forced into existence through `struct/2` — which bypasses
       `@enforce_keys` and yields `%Delayed{reason: nil}` — is dropped
       rather than rendered.

  The reason for the belt and braces is what the state is FOR. A spinner
  that does not say what it is waiting for is exactly the opacity task
  `01a07400` exists to remove; "an agent is allowed to be slow, it is not
  allowed to be opaque" is the ruling being implemented. A `:delayed` with
  no reason would be a slower `:idle` with a nicer animation — strictly
  worse than showing the underlying working state, because it replaces a
  true statement ("thinking") with a vague one.

  ## The reasons themselves come from `AgentDelayReason`, and only the
  ## specific ones

  `Platform.Meetings.AgentDelayReason` already owns the vocabulary (task
  `01a06e07` stage 2) and already infers each clause from a fact core
  holds. `from_facts/1` is the bridge, and it deliberately goes through
  `AgentDelayReason.specific_for_agent/1` rather than `for_agent/1`.

  That distinction is the honesty of this state. `specific_for_agent/1`'s
  clauses each name a cause that is genuinely holding the agent up — the
  reply budget has not reset, the agent chain needs a human, the runtime
  went offline.

  Two of `for_agent/1`'s five clauses are deliberately NOT among them, and
  `specific_for_agent/1`'s own @doc is where the reasoning lives:

    * `"still running a tool"` names nothing — it is what `for_agent/1`
      says when it has no cause and the agent has merely been working a
      while. An agent that is simply taking its time is
      `:computing`/`:thinking` and slow, not blocked, and promoting it
      would relabel every ordinary turn past ten seconds — the always-on
      badge shape canvas `01a05b11-54ff` removed `:listening` for, rebuilt
      around a different word.

    * `"no voice worker in this room"` was removed from the promotion set
      in stage 3. `apply_delays/2` only qualifies
      `AgentActivity.delayable_states/0`, which excludes `:speaking`, so
      that clause could only ever fire on an agent that is NOT speaking —
      and a missing voice worker does not hold up thinking or composing.
      It has no true configuration as a state.

  Both clauses therefore keep doing what they do today: they render as a
  trailing note beside the working state on the rail
  (`participant_rail.ex`), not as a state of their own. Nothing about that
  path changes here.

  ## Why this is a struct and not `{:delayed, reason}`

  A two-tuple would carry the reason just as unavoidably, but nothing
  stops a caller writing `{:delayed, nil}` or `{:delayed, ""}`, and there
  is no single place to reject it. A struct has a constructor, and the
  constructor is where "must have a reason" is enforced once for every
  caller.
  """

  alias Platform.Meetings.AgentDelayReason

  @enforce_keys [:reason]
  defstruct [:reason]

  @typedoc "A `:delayed` state. `reason` is always a non-blank binary."
  @type t :: %__MODULE__{reason: String.t()}

  # Same bound, and for the same reason, as
  # `AgentActivity.pushed_reason_max_chars/0`: this is a short clause
  # rendered beside a state on a rail, not a log line. Truncating rather
  # than refusing keeps the state — the load-bearing half — even when the
  # text is unreasonable.
  @reason_max_chars 200

  @doc "Maximum length of a reason; longer text is truncated, not refused."
  @spec reason_max_chars() :: pos_integer()
  def reason_max_chars, do: @reason_max_chars

  @doc """
  Build a `:delayed` state from `reason`.

  Returns `{:error, :reason_required}` for `nil`, for a non-binary, and for
  a string that is empty or only whitespace. There is no arity that omits
  the reason and no default value for it — see the moduledoc.
  """
  @spec new(term()) :: {:ok, t()} | {:error, :reason_required}
  def new(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :reason_required}
      trimmed -> {:ok, %__MODULE__{reason: String.slice(trimmed, 0, @reason_max_chars)}}
    end
  end

  def new(_reason), do: {:error, :reason_required}

  @doc """
  `new/1` for a caller that already knows it has a reason. Raises otherwise.

  Deliberately raises rather than returning a reason-less struct: a caller
  that reaches here with nothing to say has a bug at the point it gathered
  its facts, and a silent `%Delayed{reason: nil}` would carry that bug all
  the way to the screen.
  """
  @spec new!(term()) :: t()
  def new!(reason) do
    case new(reason) do
      {:ok, delayed} ->
        delayed

      {:error, :reason_required} ->
        raise ArgumentError,
              "a :delayed state requires a non-blank reason, got: #{inspect(reason)}"
    end
  end

  @doc """
  A `:delayed` for one agent from its already-gathered delay facts, or
  `:none`.

  `:none` — not `{:ok, %Delayed{reason: nil}}` and not `nil` masquerading
  as a state — is the answer whenever no SPECIFIC cause holds. That is the
  single place "no reason means no `:delayed`" is decided, so the
  guarantee cannot be half-applied by one caller and not another.

  Pure. `facts` is `AgentDelayReason.facts()`; gathering them is the render
  loop's job and costs a DB read and a presence check per agent — see that
  module's moduledoc for why it is not done here.
  """
  @spec from_facts(map()) :: {:ok, t()} | :none
  def from_facts(facts) when is_map(facts) do
    case AgentDelayReason.specific_for_agent(facts) do
      nil ->
        :none

      reason ->
        case new(reason) do
          {:ok, delayed} -> {:ok, delayed}
          {:error, :reason_required} -> :none
        end
    end
  end

  def from_facts(_facts), do: :none

  @doc """
  Whether `value` is a `%Delayed{}` that actually carries a reason.

  The third barrier from the moduledoc, and the one that runs at the point
  of use. `@enforce_keys` is a compile-time check on struct LITERALS and a
  runtime one on `struct!/2`; `struct(Delayed, %{})` slips past both and
  yields `%Delayed{reason: nil}`. `AgentActivity.apply_delays/2` asks this
  before rendering anything, so that value is dropped rather than becoming
  a reason-less `:delayed` on screen.
  """
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{reason: reason}) when is_binary(reason), do: String.trim(reason) != ""
  def valid?(_value), do: false
end
