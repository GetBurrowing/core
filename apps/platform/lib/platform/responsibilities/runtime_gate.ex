defmodule Platform.Responsibilities.RuntimeGate do
  @moduledoc """
  Pure classifier that answers "can this agent's runtime shape plausibly
  fulfill this responsibility?" (task 019f2566 stage 4).

  Motivation: an operator can `Roles.set_override/2` any agent onto any
  responsibility. The Dalton-shape trap surfaced when a federated
  conversational agent (`kind: "native"`, `runtime_type: "external"`)
  got pinned to `meetings.summarize` — the router dispatched, but the
  conversational runtime has no summarization handler, so the dispatch
  silently stalled until stage 2's sweeper picked it up.

  This module ships **signal, not rejection**. `set_override/2` still
  performs the write on `{:soft_fail, _}`; the caller logs + emits
  telemetry so we can watch the mismatch rate before hardening the gate
  into a real rejection in a follow-up.

  ## Rules (initial set)

    * `meetings.summarize` — needs a runtime that responds to a
      dispatch payload. `:ext_single_responsibility` (Hermione-shape)
      and `:loc_built_in` (in-BEAM handler) both qualify. Federated
      conversational (`:fed_conversational`) qualifies **only** when
      the agent's `metadata["responds_to_dispatch"]` is `true` — the
      explicit marker the OpenClaw bridge sets when it's wired to
      accept summarization dispatches. Anything else is
      `{:soft_fail, :conversational_agent_no_dispatch_handler}`.

    * `meetings.intent_classify` — same shape (placeholder for the
      Meeting Producer runtime landing later in the roadmap).

    * Anything else — `:ok`. This gate is opt-in per responsibility;
      we don't reason about keys we haven't audited.

  ## Return

    * `:ok` — no known mismatch.
    * `{:soft_fail, reason_atom}` — plausible mismatch. Callers should
      log + emit telemetry, then proceed with the write.

  Missing / nil `responsibility` or `agent` — `:ok`. This is a
  best-effort signal, not a validation, and we'd rather stay quiet than
  crash the write path over a lookup miss.
  """

  alias Platform.Agents.Agent
  alias Platform.Agents.Kind
  alias Platform.Responsibilities.Responsibility

  @type soft_fail_reason :: :conversational_agent_no_dispatch_handler
  @type result :: :ok | {:soft_fail, soft_fail_reason()}

  # Responsibility keys that need a "responds to dispatch" runtime.
  # Kept as an explicit list so the gate stays opt-in per key.
  @dispatch_responsibility_keys ~w(meetings.summarize meetings.intent_classify)

  @doc """
  Return `:ok` if the agent's runtime shape plausibly fulfills the
  responsibility, `{:soft_fail, reason}` otherwise.

  Accepts `nil` for either argument (lookup miss) and treats it as
  `:ok` — the gate doesn't hard-fail on missing data.

  ## Examples

      iex> alias Platform.Responsibilities.RuntimeGate
      iex> alias Platform.Agents.Agent
      iex> alias Platform.Responsibilities.Responsibility
      iex> RuntimeGate.compatible?(
      ...>   %Responsibility{key: "meetings.summarize"},
      ...>   %Agent{kind: "external"}
      ...> )
      :ok

      iex> alias Platform.Responsibilities.RuntimeGate
      iex> alias Platform.Agents.Agent
      iex> alias Platform.Responsibilities.Responsibility
      iex> RuntimeGate.compatible?(
      ...>   %Responsibility{key: "meetings.summarize"},
      ...>   %Agent{kind: "native", runtime_type: "external"}
      ...> )
      {:soft_fail, :conversational_agent_no_dispatch_handler}

      iex> alias Platform.Responsibilities.RuntimeGate
      iex> RuntimeGate.compatible?(nil, nil)
      :ok
  """
  @spec compatible?(Responsibility.t() | nil, Agent.t() | nil) :: result()
  def compatible?(nil, _), do: :ok
  def compatible?(_, nil), do: :ok

  def compatible?(%Responsibility{key: key}, %Agent{} = agent)
      when key in @dispatch_responsibility_keys do
    check_dispatch_compatible(agent)
  end

  def compatible?(%Responsibility{}, %Agent{}), do: :ok

  # `:ext_single_responsibility` (Hermione-shape) and `:loc_built_in`
  # (in-BEAM handler) both accept dispatch payloads directly.
  # `:fed_conversational` (Dalton-shape) needs the explicit
  # `responds_to_dispatch` marker in metadata.
  defp check_dispatch_compatible(%Agent{} = agent) do
    case Kind.classify(agent) do
      :ext_single_responsibility ->
        :ok

      :loc_built_in ->
        :ok

      :fed_conversational ->
        if dispatch_marker?(agent) do
          :ok
        else
          {:soft_fail, :conversational_agent_no_dispatch_handler}
        end
    end
  end

  defp dispatch_marker?(%Agent{metadata: %{} = metadata}) do
    Map.get(metadata, "responds_to_dispatch") == true
  end

  defp dispatch_marker?(_), do: false
end
