defmodule Platform.Chat.DispatchMembership do
  @moduledoc """
  The single owner of one rule: **a dispatch names a space; put the target
  agent in a writable posture there.**

  ## The gap this closes

  An agent dispatched into a space it is not a participant of cannot post
  messages and cannot create or patch canvases there — the refusal lives in
  `Platform.Chat.Canvas.ToolHandlers.create/2`, which requires a resolved
  `agent_participant_id` in its context. Nothing on the dispatch path checks
  for this, so the dispatch is *dead on arrival*: work is requested, the agent
  receives the signal, it has nowhere to put the result, and no error is raised
  anywhere a human sees it.

  Membership does not follow from creation, either. `Platform.Chat.create_channel/1`
  only stamps `kind` and delegates to `create_space/1`; the only creation-time
  auto-add in the whole context is the Historian. So "someone made the space for
  this agent" is never a reason to assume the agent is in it.

  ## Scope — why this is not a widening

  Membership is conferred **only in the space the dispatch already named**.
  There is no roster walk, no org-wide fan-out, no "and its sibling channels".
  That boundary is the entire answer to "is auto-invite always right": the
  invite happens exactly where something server-side already resolved *this
  agent* as the target *of that space*. A broader rule would silently widen who
  can read a space's history, which is a different decision and not one this
  module is allowed to make.

  ## DMs are refused, deliberately

  `Platform.Chat`'s mention-reinvite path exempts DMs by contract ("DM privacy
  guard: do not auto-add agents to DMs on @-mention"). An auto-invite that
  ignored that would be a backdoor into private conversations through a door
  the mention path already locked. Both `kind == "dm"` and `is_direct == true`
  are refused; the schema only permits `is_direct` on `kind == "dm"` today, but
  checking both means a future direct-ish kind cannot slip through by being
  spelled differently.

  ## ADR-0038: this CAN resurrect a dismissed agent

  Dismissal is a hard delete — post-ADR-0038 "either the row exists (already in
  the space) or it doesn't (dismissed and hard-deleted)". There is therefore no
  state this function could read that distinguishes *never invited* from *a
  human dismissed me five minutes ago*, and a later dispatch naming that space
  will re-add the agent.

  That is accepted deliberately, not overlooked. A durable dismissal record is a
  separate change with its own migration and its own UI consequences. What makes
  the tradeoff acceptable in the meantime is that the resurrection is
  **observable**: every call emits `[:platform, :chat, :dispatch_auto_invite]`
  carrying the space, the agent, and the `:source` that asked. Do not remove
  that telemetry to "reduce noise" — it is the only thing standing between this
  behaviour and a silent one.

  ## Refusals are distinct atoms, and that is load-bearing

  `:no_space_named`, `:invalid_space_id`, `:space_not_found`, `:space_archived`,
  `:direct_space`, `:no_agent_named`, `:agent_not_found`,
  `:ambiguous_agent_slug` and `:insert_failed` are nine separate values because
  they are nine separate operator situations. (`:ambiguous_agent_slug`, task
  01a0e77c: the slug names agents in more than one workspace; the fix is to
  address the agent by UUID, not to create one.) Collapsing any of them into a shared `:refused` / `:skipped` is
  the exact defect `Platform.Responsibilities.Providers` was written to kill:
  when "the module was never written" and "this feature deliberately has no
  provider" produced the same value, `architecture.*` sat broken for months and
  nothing in the logs distinguished it from a key that was *supposed* to be
  unhandled.

  Concretely: an archived meeting, a deleted meeting space, and a dispatch that
  simply never named a space have three different fixes. A test that only
  asserts `{:skip, _}` cannot tell them apart, and neither can whoever is paged.

  ### `:insert_failed` is the one that must not be lost

  The insert has exactly one *benign* failure: a concurrent writer inserted the
  row between our pre-check and ours, so the row is there and
  `{:ok, :already_member}` is the literal truth. Every other failure — a
  rejected changeset, a constraint that is not the uniqueness one, a space
  archived between this module's policy check and `Chat.add_participant/2`'s own
  writability check — leaves **no row at all**.

  Reporting those as `:already_member` would be a failed write reported as a
  success. That is the same collapse as the others except it lands on the
  `{:ok, _}` side of the return, which is strictly worse: the caller believes
  the agent can write the space, the agent cannot, and telemetry says everything
  is fine. The re-lookup in `do_invite/3` is what separates the two cases, and
  it is not an optimisation — it is the entire distinction.

  ### Refusal precedence

  Precedence is fixed, documented and pinned by a test — not an accident of
  clause order. **Space-shaped refusals are evaluated before agent-shaped
  ones**, in this order:

      :no_space_named -> :invalid_space_id -> :space_not_found
        -> :direct_space -> :space_archived
        -> :no_agent_named -> :agent_not_found | :ambiguous_agent_slug
        -> :insert_failed

  Space first because the space is what the dispatch *named*: it is the scope
  the entire policy is defined against, and an operator repairing a broken
  dispatch has to fix the space half before the agent half can even be
  evaluated. So `ensure_writable(nil, nil, ...)` deterministically returns
  `:no_space_named`, never `:no_agent_named`.

  That exact call is pinned by a test. Do not "tidy" `resolve_and_invite/3` into
  resolving both halves up front and picking a winner, and do not flip the two
  `case` levels: either change still satisfies every one-atom-per-refusal test
  in the suite while silently swapping which refusal an operator is paged with.

  Within space resolution the DM guard is checked **before** the archived guard:
  a DM must never report as merely archived, because the privacy refusal is a
  policy statement that should not be masked by lifecycle state.

  `:insert_failed` is last by construction — it is the only refusal that
  requires every other check to have already passed.

  ## Attention mode is chosen by space kind

    * `"execution"` -> `"all"`. The assigned agent must hear every TaskRouter
      engagement message in its own task's execution space, not only the ones
      that happen to @-mention it. This preserves the intent of
      `Platform.Orchestration.ExecutionSpace.add_participant/2`, which a later
      stage of this task deletes precisely so there are not two mechanisms
      saying one thing.
    * everything else -> `"mention"`, matching `Chat.add_agent_participant/3`'s
      own default and the mention-reinvite path.

  Role is always the schema default `"member"`. Never `"principal"` — a dispatch
  target is a worker in the space, not its owner.

  ## Idempotence

  The insert is delegated to `Chat.add_agent_participant/3`, which is already
  find-or-insert, so calling this twice cannot produce two rows. The
  `:invited` / `:already_member` distinction comes from a
  `Chat.get_agent_participant/2` pre-check. That distinction is what makes an
  idempotence test non-vacuous: an assertion matching only `{:ok, _}` cannot
  tell one row from two.

  There is a narrow window where a concurrent writer inserts between our
  pre-check and the delegate's own lookup, in which case we report `:invited`
  for a row we did not personally insert. The row count is still correct — only
  the label is optimistic — and closing it would mean duplicating the
  find-or-insert instead of delegating to it.

  On the reverse race (pre-check says absent, insert errors) we re-look-up and
  report `:already_member`, mirroring `Platform.Meetings.Membership`'s
  `ensure_chat_space_participant/3`.

  ## Never raises

  Every caller sits on a best-effort dispatch path whose documented contract is
  always-`:ok`. A raise here would turn a *writability* problem into a *delivery*
  failure, which is strictly worse: an agent that receives a dispatch it cannot
  write to still beats one that never receives it. So the body is wrapped and
  any exception or exit becomes `{:skip, {:raised, msg}}` / `{:skip, {:exited, msg}}`.
  """

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Chat.Space
  alias Platform.Repo

  @telemetry_event [:platform, :chat, :dispatch_auto_invite]

  @typedoc """
  Why no invite happened. Each value is a distinct operator situation — see the
  moduledoc on why these are never collapsed.
  """
  @type skip_reason ::
          :no_space_named
          | :invalid_space_id
          | :space_not_found
          | :space_archived
          | :direct_space
          | :no_agent_named
          | :agent_not_found
          | :ambiguous_agent_slug
          | {:insert_failed, term()}
          | {:raised, String.t()}
          | {:exited, String.t()}

  @type result :: {:ok, :invited} | {:ok, :already_member} | {:skip, skip_reason()}

  @doc """
  Ensure `agent_id` is a participant of `space_id` in a writable posture.

  Returns `{:ok, :invited}` when a row was created, `{:ok, :already_member}`
  when one already existed, or `{:skip, reason}` when policy or resolution
  refused. Never raises.

  ## Options

    * `:source` — which dispatch surface asked. The vocabulary is
      `t:Platform.Federation.AttentionDispatch.source/0`; keep the two in step.
      Carried through to telemetry so a resurrection or a refusal can be traced
      back to the dispatcher that caused it. Defaults to `nil`.
    * `:display_name` — override the participant's display name. Defaults to the
      agent's own name.

  ## Telemetry

  Emits `[:platform, :chat, :dispatch_auto_invite]` on **every** call, including
  refusals, with measurements `%{count: 1}` and metadata
  `%{space_id, agent_id, space_kind, outcome, source, detail}`.

  `:outcome` is always a bare atom so aggregators can group on it without
  unbounded cardinality; for the compound reasons (`{:raised, msg}` and friends)
  the outcome is the leading atom and the variable part moves to `:detail`.
  `:space_kind` is `nil` whenever the space did not resolve.
  """
  @spec ensure_writable(binary() | nil, binary() | Agent.t() | nil, keyword()) :: result()
  def ensure_writable(space_id, agent_id, opts \\ []) do
    {result, space_kind} =
      try do
        resolve_and_invite(space_id, agent_id, opts)
      rescue
        e -> {{:skip, {:raised, Exception.message(e)}}, nil}
      catch
        :exit, reason -> {{:skip, {:exited, inspect(reason)}}, nil}
      end

    emit(result, space_id, agent_id, space_kind, Keyword.get(opts, :source))
    result
  end

  # ── Resolution ─────────────────────────────────────────────────────────────

  # Space resolution is the OUTER case and that is load-bearing, not stylistic:
  # it is what makes `ensure_writable(nil, nil, _)` report `:no_space_named`
  # rather than `:no_agent_named`. See "Refusal precedence" in the moduledoc for
  # why space wins. Flattening these two levels into a single `with` that
  # resolves both halves first, or swapping them, changes the atom an operator
  # is paged with for an ambiguous dispatch — a test pins the exact call.
  defp resolve_and_invite(space_id, agent_id, opts) do
    case resolve_space(space_id) do
      {:skip, reason, kind} ->
        {{:skip, reason}, kind}

      {:ok, %Space{} = space} ->
        case resolve_agent(agent_id) do
          {:skip, reason} -> {{:skip, reason}, space.kind}
          {:ok, %Agent{} = agent} -> {invite(space, agent, opts), space.kind}
        end
    end
  end

  defp resolve_space(nil), do: {:skip, :no_space_named, nil}

  defp resolve_space(space_id) when is_binary(space_id) do
    # Platform.UUID.valid?/1, NOT a bare Ecto.UUID.cast/1: a cast hex-encodes
    # any 16-byte binary, so a 16-character slug clears it and then raises
    # inside Repo against the strict UUIDv7 primary key. Same reasoning as
    # `Chat.get_space/1`.
    if Platform.UUID.valid?(space_id) do
      classify_space(Repo.get(Space, space_id))
    else
      {:skip, :invalid_space_id, nil}
    end
  end

  defp resolve_space(_other), do: {:skip, :invalid_space_id, nil}

  defp classify_space(nil), do: {:skip, :space_not_found, nil}

  # DM guard first — see "Refusal precedence" in the moduledoc.
  defp classify_space(%Space{kind: "dm"} = space), do: {:skip, :direct_space, space.kind}
  defp classify_space(%Space{is_direct: true} = space), do: {:skip, :direct_space, space.kind}

  defp classify_space(%Space{archived_at: %DateTime{}} = space),
    do: {:skip, :space_archived, space.kind}

  defp classify_space(%Space{} = space), do: {:ok, space}

  defp resolve_agent(nil), do: {:skip, :no_agent_named}
  defp resolve_agent(%Agent{} = agent), do: {:ok, agent}

  defp resolve_agent(agent_id) when is_binary(agent_id) do
    # Agents are addressed by UUID *or* slug across the dispatch surfaces, so
    # both lookups are real paths, not defensive padding.
    # A slug shared across workspaces is its own refusal,
    # `:ambiguous_agent_slug`, not `:agent_not_found`: the fix is to name the
    # agent by UUID, not to create it (task 01a0e77c).
    found =
      if Platform.UUID.valid?(agent_id) do
        Repo.get(Agent, agent_id)
      else
        Platform.Agents.SlugLookup.resolve(agent_id)
      end

    case found do
      %Agent{} = agent -> {:ok, agent}
      {:ok, %Agent{} = agent} -> {:ok, agent}
      {:error, :ambiguous_slug} -> {:skip, :ambiguous_agent_slug}
      _ -> {:skip, :agent_not_found}
    end
  end

  # Something was named, it just is not resolvable to an agent. Distinct from
  # `:no_agent_named`, which means nothing was named at all.
  defp resolve_agent(_other), do: {:skip, :agent_not_found}

  # ── Insert ─────────────────────────────────────────────────────────────────

  defp invite(%Space{} = space, %Agent{} = agent, opts) do
    case Chat.get_agent_participant(space.id, agent.id) do
      %Participant{} -> {:ok, :already_member}
      nil -> do_invite(space, agent, opts)
    end
  end

  defp do_invite(%Space{} = space, %Agent{} = agent, opts) do
    add_opts =
      [attention_mode: attention_mode(space.kind)]
      |> maybe_put_display_name(Keyword.get(opts, :display_name))

    case Chat.add_agent_participant(space.id, agent, add_opts) do
      {:ok, %Participant{}} ->
        {:ok, :invited}

      {:error, reason} ->
        # Two very different situations arrive here and this re-lookup is the
        # only thing that tells them apart:
        #
        #   * a row is present — a concurrent writer inserted between our
        #     pre-check and this insert. We lost a race; the desired state
        #     holds. Idempotent success, mirroring
        #     Platform.Meetings.Membership.ensure_chat_space_participant/3.
        #   * no row — the write genuinely failed (rejected changeset, a
        #     non-uniqueness constraint, or the space archived under us between
        #     classify_space/1 and Chat.add_participant/2's own guard).
        #
        # Do not collapse the second into the first "because it's simpler".
        # `{:ok, :already_member}` for an absent row is a failed write reported
        # as a success — see ":insert_failed is the one that must not be lost".
        case Chat.get_agent_participant(space.id, agent.id) do
          %Participant{} ->
            {:ok, :already_member}

          nil ->
            Logger.warning(
              "[Chat.DispatchMembership] invite failed space=#{space.id} " <>
                "agent=#{agent.id}: #{inspect(reason)}"
            )

            {:skip, {:insert_failed, reason}}
        end
    end
  end

  defp maybe_put_display_name(add_opts, nil), do: add_opts
  defp maybe_put_display_name(add_opts, name), do: Keyword.put(add_opts, :display_name, name)

  # Execution spaces are the one kind where the dispatch target must hear every
  # message, not just the ones naming it — the TaskRouter's engagement messages
  # do not @-mention the assignee.
  defp attention_mode("execution"), do: "all"
  defp attention_mode(_kind), do: "mention"

  # ── Telemetry ──────────────────────────────────────────────────────────────

  defp emit(result, space_id, agent_id, space_kind, source) do
    {outcome, detail} = describe(result)

    :telemetry.execute(@telemetry_event, %{count: 1}, %{
      space_id: space_id,
      agent_id: agent_id_for_telemetry(agent_id),
      space_kind: space_kind,
      outcome: outcome,
      source: source,
      detail: detail
    })

    :ok
  end

  defp describe({:ok, outcome}), do: {outcome, nil}
  defp describe({:skip, reason}) when is_atom(reason), do: {reason, nil}
  defp describe({:skip, {reason, detail}}) when is_atom(reason), do: {reason, detail}

  defp agent_id_for_telemetry(%Agent{id: id}), do: id
  defp agent_id_for_telemetry(other), do: other
end
