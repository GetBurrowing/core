defmodule Platform.Federation.AttentionDispatch do
  @moduledoc """
  The **only** module under `apps/platform/lib` permitted to call
  `PlatformWeb.Endpoint.broadcast(topic, "attention", payload)`.

  ## Why a funnel, and why this one

  "Where exactly is the boundary?" is the question every auto-invite design has
  to answer, and the answer here is: the boundary is the one primitive every
  dispatch surface already shares. Meetings, the TaskRouter and the chat
  responder have nothing else in common — different resolution chains, different
  telemetry, different failure vocabularies — but all of them end at an
  `"attention"` broadcast on `runtime:<runtime_id>`, because that is the topic
  `PlatformWeb.RuntimeChannel.join/3` matches.

  Hanging the writability check off that primitive means a *new* dispatcher
  cannot be written that skips the invite without also skipping delivery. A
  helper anyone could forget to call would have been a convention; this is a
  chokepoint. The regression guard that keeps it one is a source scan asserting
  this file is the only match for `Endpoint.broadcast(_, "attention", _)`.

  ## Order is load-bearing

  `Platform.Chat.DispatchMembership.ensure_writable/3` runs **and commits**
  before `PlatformWeb.Endpoint.broadcast/3`. Not "nearby", not "in the same
  function" — strictly before, with the participant row durable by the time the
  signal leaves.

  A runtime can act on an attention within milliseconds: it is a live WebSocket
  push, and the receiving agent's first move is typically a tool call against
  the space it was just told about. Inviting *after* the broadcast reintroduces
  exactly the dead-on-arrival window this whole change exists to close, only
  narrower and therefore harder to reproduce — the agent's `canvas_create` races
  the invite and loses intermittently. A test asserting merely that both things
  happened would pass with the order inverted, so the ordering test in
  `test/platform/federation/attention_dispatch_test.exs` reads the mailbox
  positionally rather than selectively.

  ## An invite refusal never changes the broadcast decision

  Every refusal and every failure from `ensure_writable/3` is discarded here.
  The signal goes out regardless.

  A dispatch the agent can read but not write is strictly better than one it
  never receives: the first is a degraded delivery the agent can report on, the
  second is silence. And the refusal is not lost — stage 1's
  `[:platform, :chat, :dispatch_auto_invite]` telemetry fires on *every* call,
  refusals included, carrying the distinct reason atom. Turning a writability
  problem into a delivery failure would be strictly worse than the bug.

  ## `:space_id` is an option, never sniffed out of the payload

  This module does not look inside `payload` for a space. Callers pass
  `space_id:` explicitly.

  That separation is what protects the constraint documented at length in
  `Platform.Chat.AgentResponder` (`build_system_event_payload/1`): the
  `claude-code-suite-channel` client pins the space a pending permission prompt
  gets answered in to the **top-level `signal.space_id`**, so a background fire
  that lifted its own `space_id` onto the wire would silently relocate a live
  approval prompt to a space nobody is watching. If this module derived the
  space from the payload, "the funnel knows which space to invite into" and "the
  wire payload claims that slot" would become the same decision, and the only
  way to get an invite would be to break the prompt. Keeping it an option means
  the funnel can know a space the payload does not name — which is precisely the
  case a later stage needs for meeting-intent dispatch, where the space travels
  as `target_space_id`.

  ## Errors

  `{:error, :broadcast_failed}` and `{:error, :endpoint_not_ready}` are the same
  two atoms the three `Platform.Federation.dispatch_*_attention/2` fallbacks
  already report, so migrating onto this module changes no telemetry vocabulary.
  The underlying error term is logged here rather than returned: the pinned
  return shape is a closed set of atoms so callers can pattern-match it without
  a catch-all, and an unbounded term in a telemetry metadata field is
  cardinality nobody aggregates on.

  The `rescue ArgumentError` is scoped to the broadcast alone, deliberately.
  `ensure_writable/3` has its own never-raises contract and its own reason
  vocabulary; folding it inside the rescue would let an invite bug surface as
  `:endpoint_not_ready` — a resolution failure disguised as an infrastructure
  one, which is the reason-collapsing defect this task keeps refusing to
  introduce.
  """

  require Logger

  alias Platform.Chat.DispatchMembership

  @typedoc """
  Which dispatch surface asked. Carried to
  `[:platform, :chat, :dispatch_auto_invite]` so an auto-invite can be traced
  back to the dispatcher that caused it.

  `:dead_letter_replay` is its own value rather than reusing `:agent_responder`,
  even though every row it replays was originally captured on the responder's
  system_event path. A first delivery and a delivery that already failed once
  are different operator situations, and folding them together is the reason
  collapse this task keeps refusing — telemetry would show a steady trickle of
  invites with no way to tell a live dispatch from a drain.
  """
  @type source ::
          :meeting_scribe
          | :meeting_triage
          | :meeting_intent
          | :task_router
          | :agent_responder
          | :dead_letter_replay

  @type result :: :ok | {:error, :broadcast_failed | :endpoint_not_ready}

  @doc """
  The PubSub topic a federated runtime is subscribed to.

  Keyed by the `AgentRuntime`'s external `runtime_id` STRING, not by `agent_id`
  — that is the topic `PlatformWeb.RuntimeChannel.join/3` matches. Exposed so
  callers building log lines about a dispatch spell the topic the same way the
  dispatch does.
  """
  @spec topic(binary()) :: binary()
  def topic(runtime_id) when is_binary(runtime_id), do: "runtime:#{runtime_id}"

  @doc """
  Put the target agent in a writable posture, then broadcast an `"attention"`
  event to its runtime.

  ## Options

    * `:space_id` — the space this dispatch names, or `nil`. `nil` is a
      first-class value, not an omission: it resolves to a clean
      `:no_space_named` skip and the broadcast still goes out.
    * `:agent_id` — the target agent (id, slug, or `%Platform.Agents.Agent{}`).
    * `:source` — which dispatch surface asked. See `t:source/0`.

  Returns `:ok`, or `{:error, :broadcast_failed | :endpoint_not_ready}` when the
  broadcast itself fails. The invite result is deliberately not reflected in the
  return value — see the moduledoc.
  """
  @spec broadcast(binary(), map(), keyword()) :: result()
  def broadcast(runtime_id, payload, opts \\ [])
      when is_binary(runtime_id) and is_map(payload) and is_list(opts) do
    # BEFORE the broadcast, and committed. Not a stylistic ordering — see
    # "Order is load-bearing" in the moduledoc. Do not move this below
    # do_broadcast/2, and do not make it concurrent with it.
    _ =
      DispatchMembership.ensure_writable(
        Keyword.get(opts, :space_id),
        Keyword.get(opts, :agent_id),
        source: Keyword.get(opts, :source)
      )

    do_broadcast(topic(runtime_id), payload)
  end

  # The rescue covers the broadcast ONLY. See "Errors" in the moduledoc for why
  # ensure_writable/3 is deliberately outside it.
  defp do_broadcast(topic, payload) do
    case PlatformWeb.Endpoint.broadcast(topic, "attention", payload) do
      :ok ->
        :ok

      {:error, err} ->
        Logger.warning("[AttentionDispatch] broadcast failed to #{topic}: #{inspect(err)}")

        {:error, :broadcast_failed}
    end
  rescue
    error in ArgumentError ->
      Logger.warning(
        "[AttentionDispatch] endpoint not ready while broadcasting to #{topic}: " <>
          Exception.message(error)
      )

      {:error, :endpoint_not_ready}
  end
end
