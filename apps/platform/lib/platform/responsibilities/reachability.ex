defmodule Platform.Responsibilities.Reachability do
  @moduledoc """
  Answers "which responsibilities can actually reach a live runtime?" as a
  query instead of a hand audit (task `019fa510` stage 1).

  ## THE NON-CLAIM — read this before quoting any number out of `report/0`

  **`:broadcastable` means the SERVER would broadcast. It says NOTHING
  about whether the receiving client parses the envelope.**

  That non-claim is the entire reason this module exists. Between the
  introduction of the `system_event` envelope and 2026-07-27, every
  responsibility dispatch to a Claude Code runtime arrived as an *empty*
  message: the client read `payload.message.content`, but a `system_event`
  envelope built by `Platform.Chat.AgentResponder.build_system_event_signal/2`
  carries no `message` key at all — the rendered prompt lives at
  `signal.prompt`. Throughout that window the server was correct, the
  broadcast fired, `[AgentResponder] broadcasting system_event` was logged,
  and this module would have reported `:broadcastable`. The work still did
  not happen.

  A reader who takes `:broadcastable` to mean "this responsibility works"
  has reproduced the exact error that let that bug live for days:
  server-side correctness was never in doubt, and asserting it proves
  nothing about delivery. `:broadcastable` is the *last* thing `core` can
  measure, not the thing you care about. Delivery evidence has to come from
  the receiving runtime's own logs.

  ## Why a new module rather than asking the Router

  `Platform.Responsibilities.Router` is a GenServer that only knows the rows
  it subscribed at boot (`router.ex:209`), so asking it would report the
  boot-time snapshot rather than the live table. Operator toggles of
  `enabled`, role reassignments, and runtimes that connected or dropped
  since boot are all invisible to it. This enumerator reads
  `responsibilities` fresh on every call, resolves assignees through the
  real `Platform.Roles.assignee_for/1` the dispatcher uses, and reads live
  `Platform.Federation.RuntimePresence` state. That distinction is the whole
  reason the audit is being done at all.

  ## The five classes, and what falsifies each

  Each class mirrors one branch of the real dispatch path in
  `Platform.Chat.AgentResponder`. They are deliberately **distinct** rather
  than collapsed into a single `:unreachable`, because the remediation for
  each is different and the audit downstream of this module has to tell them
  apart.

    * `:unfilled` — `Platform.Roles.assignee_for/1` returns `nil`. Nobody
      holds the responsibility. This is **progressive enhancement, not a
      failure** — the same rule `Platform.Responsibilities.outcome/1` applies
      when it maps `{:ok, :unfilled}` to `:not_applicable`. Do not render it
      as a casualty.
      *Falsified by:* an override row or a role bundle that resolves the key.
      Assign an agent and the class moves.

    * `:builtin_handler` — an assignee resolves but its `runtime_type` is not
      `"external"`. `AgentResponder.dispatch_system_event/2`'s second clause
      (`agent_responder.ex:404`) logs and skips; the deterministic handler
      path owns the work. Nothing is broadcast and nothing should be.
      *Falsified by:* the agent's `runtime_type` reading `"external"`, or by
      evidence that a built-in agent's responsibility output is in fact
      produced through the chat dispatch path.

    * `:runtime_missing` — `runtime_type == "external"` but there is no
      runtime row to reach. Two sub-cases in principle, and they are NOT
      equally reachable:
        - `runtime_id` is `nil` — the agent claims to be external but names
          no runtime. **This is the one that actually occurs.** It does not
          even reach the `get_runtime/1` lookup: the first
          `dispatch_system_event/2` clause is guarded `when
          is_binary(runtime_pk)`, so a nil id falls through to the *built-in*
          clause and logs `built-in agent … chat-context dispatch skipped`.
          Anyone grepping that log line to count built-in handlers is also
          counting these, and this report is how you tell them apart.
        - `runtime_id` set but `Platform.Federation.get_runtime/1` returns
          `nil` — the dangling-FK case at `agent_responder.ex:390`, which
          logs `system_event dispatch skipped — runtime … not found`.
          Established while writing this module: `agents.runtime_id` is
          `references(:agent_runtimes, on_delete: :nilify_all)`
          (`20260319140000_create_agent_runtimes.exs:32`), so deleting a
          runtime *nils the pointer* rather than leaving it dangling. This
          sub-case is unreachable through ordinary data flow — only a race
          (runtime deleted between the agent read and the lookup) or a
          dropped constraint produces it. Both sub-cases classify the same
          because the reachability outcome is identical.
      *Falsified by:* the `agent_runtimes` row existing under that primary
      key. This is a pure row-existence check with no timing component.

    * `:runtime_offline` — the runtime row exists but
      `RuntimePresence.online?/1` is false. This is the DeadLetterBuffer path
      at `agent_responder.ex:449`; the signal is recorded and dropped.
      *Falsified by:* the runtime reconnecting. Unlike `:runtime_missing`
      this class is **time-varying** — it is a snapshot of presence at the
      instant `report/0` ran, and a key that reads `:runtime_offline` at
      03:00 may read `:broadcastable` at 09:00. Never quote it as a standing
      property.

    * `:broadcastable` — the broadcast at `agent_responder.ex:431` would
      fire. See the non-claim at the top of this moduledoc.
      *Falsified by:* Burrow's own logs showing no `[AgentResponder]
      broadcasting system_event` line for the key over a window in which its
      trigger demonstrably fired. If that happens the classifier is modelling
      the wrong thing and nothing downstream should build on it.

  `:unfilled` and `:runtime_offline` can never collapse onto the same value:
  the first is decided before any runtime is consulted (`:runtime_online?` is
  `nil`), the second requires a resolved external assignee *and* an existing
  runtime row (`:runtime_online?` is `false`).

  ## "Deliberately inert" is NOT a class — it is an orthogonal axis

  The five classes above answer *"if this responsibility fired, would the
  signal reach a live runtime?"*. They say nothing about whether it ever
  fires. Those are different questions and collapsing them would make the
  audit wrong in the most expensive direction — by counting rows that were
  never meant to fire as casualties of a delivery bug.

  The concrete case: the four `security.*` keys register as `event_topic`
  bound to a **sentinel topic no publisher ever broadcasts to**
  (`"platform.security.sweeper_only"`, see
  `responsibilities/handlers/security_cve_scan.ex` and ADR-0043). They are
  inert **by design**, they were never firing, and they are *not* casualties
  of anything. Yet their assignee resolves fine, so on the reachability axis
  alone several of them classify as `:broadcastable`.

  So each row also carries three fields read **verbatim off the row's own
  `metadata`** — declared facts, not inferences:

    * `:declared_status` — `metadata["status"]`. Providers set `"active"` or
      `"placeholder"`; `nil` when the provider declares nothing.
    * `:declared_executor` — `metadata["executor"]`. Non-nil means the row
      itself declares that some runtime *other than the Router* owns firing
      it (today: `"platform.security.sweeper"`).
    * `:declared_inert?` / `:declared_inert_reason` — true when either of the
      above says so, with `:non_router_executor` or `:placeholder_status`
      naming which field produced it.

  *Falsified by:* the provider changing its declaration, or by a
  `[AgentResponder] broadcasting system_event` line appearing for a key this
  reports as `declared_inert?: true`. The second would mean a publisher
  exists that the declaration denies, and the declaration is the thing that
  is wrong.

  The field is named `declared_inert?` rather than `inert?` on purpose: it
  reports what the row *declares*, which is a thing this module can read. It
  is not a claim that no publisher exists — that would need a whole-repo
  publisher census this module does not do.

  One thing this axis deliberately does NOT cover: a key whose trigger has no
  production caller — nobody ever calls `Platform.Responsibilities.fire/2`
  with it. Such a key can classify `:broadcastable` and be `declared_inert?:
  false` and still never fire once, because the row describes a subscription
  and the caller graph describes the publisher. This module reads rows, so it
  cannot see that and does not pretend to.

  The live examples, established by the production audit in task `019fa510`
  stage 2: `meetings.action_items` and `meetings.attendance_followup` both
  declare `topic: "meeting:finished"` and both classify `:broadcastable`, but
  the whole application contains exactly three `Responsibilities.fire/2` call
  sites — `design/preplan_step.ex:587`, `tasks.ex:1965` and
  `tasks/plan_engine.ex:610` — and none of them fires a `meetings.*` key.
  Four meetings ended in the audited window and produced zero
  `[AgentResponder] broadcasting system_event` lines for either key. They are
  unwired, not broken, and counting them as casualties of a delivery defect
  would be wrong.

  `design.task_direction` was cited here as that example when this module was
  written; production falsified it. `Platform.Design.PreplanStep` (ADR-0046
  member 7) has landed and calls both `Responsibilities.fire/2` (`:587`) and
  `Platform.Tasks.record_planning_step(task, :design, _)` (`:509`, `:557`).
  The key fired four times on 2026-07-27 and wrote four `design_timeout`
  outcomes, so an empty design outcome is NOT expected and IS evidence.

  ## Usage

      iex> Platform.Responsibilities.Reachability.classes()
      [:unfilled, :builtin_handler, :runtime_missing, :runtime_offline, :broadcastable]

  From a release console:

      Platform.Responsibilities.Reachability.report() |> IO.inspect(limit: :infinity)

  Or the rendered form, which is what `mix burrow.responsibility_reachability`
  prints:

      Platform.Responsibilities.Reachability.render()
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo
  alias Platform.Responsibilities.Responsibility
  alias Platform.Roles

  @classes [:unfilled, :builtin_handler, :runtime_missing, :runtime_offline, :broadcastable]

  @typedoc "Closed set of reachability classifications."
  @type class ::
          :unfilled | :builtin_handler | :runtime_missing | :runtime_offline | :broadcastable

  @typedoc "Why a row declares itself inert, or `nil` when it does not."
  @type inert_reason :: :non_router_executor | :placeholder_status | nil

  @typedoc "One report row."
  @type row :: %{
          key: String.t(),
          trigger_kind: String.t(),
          feature: String.t(),
          topic: String.t() | nil,
          assignee_slug: String.t() | nil,
          assignee_id: String.t() | nil,
          runtime_type: String.t() | nil,
          runtime_id: String.t() | nil,
          runtime_online?: boolean() | nil,
          class: class(),
          declared_status: String.t() | nil,
          declared_executor: String.t() | nil,
          declared_inert?: boolean(),
          declared_inert_reason: inert_reason()
        }

  @doc """
  The closed set of `:class` values `report/0` can emit, in escalating
  order of "how far down the dispatch path this row gets".

  Exposed so callers (and the admin UI, and tests) can enumerate the set
  without pattern-matching on a literal list that might drift.
  """
  @spec classes() :: [class()]
  def classes, do: @classes

  @doc """
  One map per **enabled** row in `responsibilities`, ordered by key.

  Disabled rows are omitted entirely: the operator kill-switch means the
  Router never even considers them (`Responsibilities.get_by_trigger/1`
  pre-filters on `enabled`), so reporting a reachability class for one would
  be describing a path that cannot be taken.

  Reads the table fresh on every call — see the moduledoc on why asking the
  Router instead would give you a boot-time snapshot.

  Raises when `Platform.Federation.RuntimePresence` is not running, rather
  than degrading to "everything is offline". A presence map that cannot be
  read is not the same measurement as a presence map that is empty, and
  silently substituting one for the other is exactly the class of error this
  module was written to stop.
  """
  @spec report() :: [row()]
  def report do
    ensure_presence_readable!()

    enabled_responsibilities()
    |> Enum.map(&classify/1)
  end

  @doc """
  Render `report/0` (or a supplied report) as the operator-facing string
  `mix burrow.responsibility_reachability` prints: a fixed-width table, a
  class tally, and one machine-readable `REACH ...` line per row for
  copy-paste out of a release RPC console session.

  Rendering lives here rather than in the Mix task so it is unit-testable
  and so a release console with no Mix available can call it directly.
  """
  @spec render([row()] | nil) :: String.t()
  def render(rows \\ nil) do
    rows = rows || report()

    Enum.join(
      [
        header(rows),
        table(rows),
        tally(rows),
        machine_readable(rows),
        caveat()
      ],
      "\n"
    )
  end

  # ── classification ─────────────────────────────────────────────────────────

  defp enabled_responsibilities do
    Repo.all(from(r in Responsibility, where: r.enabled == true, order_by: [asc: r.key]))
  end

  defp classify(%Responsibility{} = responsibility) do
    responsibility
    |> base_row()
    |> Map.merge(assignee_fields(Roles.assignee_for(responsibility.key)))
    |> put_class()
  end

  defp base_row(%Responsibility{} = r) do
    metadata = r.metadata || %{}
    status = string_or_nil(Map.get(metadata, "status"))
    executor = string_or_nil(Map.get(metadata, "executor"))
    reason = inert_reason(executor, status)

    %{
      key: r.key,
      trigger_kind: r.trigger_kind,
      feature: r.feature,
      topic: string_or_nil(Map.get(r.trigger_config || %{}, "topic")),
      declared_status: status,
      declared_executor: executor,
      declared_inert?: not is_nil(reason),
      declared_inert_reason: reason
    }
  end

  # `metadata["executor"]` is checked first because it is the stronger
  # statement: it names a specific non-Router owner, whereas
  # `status: "placeholder"` only says the row's own runtime has not landed.
  # A row can carry both (the security.* keys do) and the executor is the
  # more useful thing to report.
  defp inert_reason(executor, _status) when is_binary(executor), do: :non_router_executor
  defp inert_reason(_executor, "placeholder"), do: :placeholder_status
  defp inert_reason(_executor, _status), do: nil

  defp assignee_fields(nil) do
    %{
      assignee_slug: nil,
      assignee_id: nil,
      runtime_type: nil,
      runtime_id: nil,
      runtime_online?: nil
    }
  end

  defp assignee_fields(%{slug: slug, id: id, runtime_type: "external", runtime_id: runtime_pk}) do
    base = %{
      assignee_slug: slug,
      assignee_id: id,
      runtime_type: "external",
      runtime_id: nil,
      runtime_online?: nil
    }

    # A nil `runtime_id` never reaches `get_runtime/1` at all — the first
    # `dispatch_system_event/2` clause is guarded `when is_binary(runtime_pk)`.
    # Reported as :runtime_missing all the same because the reachability
    # outcome is identical: there is no runtime to reach.
    case runtime_pk && Federation.get_runtime(runtime_pk) do
      nil ->
        base

      runtime ->
        %{base | runtime_id: runtime.runtime_id, runtime_online?: online?(runtime.runtime_id)}
    end
  end

  defp assignee_fields(%{slug: slug, id: id, runtime_type: runtime_type}) do
    %{
      assignee_slug: slug,
      assignee_id: id,
      runtime_type: runtime_type,
      runtime_id: nil,
      runtime_online?: nil
    }
  end

  defp put_class(%{assignee_id: nil} = row), do: Map.put(row, :class, :unfilled)

  defp put_class(%{runtime_type: "external"} = row) do
    class =
      case row.runtime_online? do
        nil -> :runtime_missing
        false -> :runtime_offline
        true -> :broadcastable
      end

    Map.put(row, :class, class)
  end

  defp put_class(row), do: Map.put(row, :class, :builtin_handler)

  defp online?(runtime_id) when is_binary(runtime_id), do: RuntimePresence.online?(runtime_id)

  defp ensure_presence_readable! do
    if is_nil(Process.whereis(RuntimePresence)) do
      raise """
      Platform.Federation.RuntimePresence is not running, so runtime presence \
      cannot be read and no row can be classified.

      Reporting every runtime as offline here would be a different measurement \
      wearing the same name — :runtime_offline would then mean "presence was \
      unreadable" rather than "the runtime was not connected", and the audit \
      built on top of it would be counting the wrong thing.

      Start it (it is normally supervised by Platform.Application) and re-run.
      """
    end

    :ok
  end

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  # ── rendering ──────────────────────────────────────────────────────────────

  @columns [
    {"KEY", :key, 34},
    {"CLASS", :class, 16},
    {"TRIGGER", :trigger_kind, 13},
    # 32 clears `platform.security.sweeper_only` (30) plus a separating gap —
    # at 30 the security.* rows butted straight into the ASSIGNEE column.
    {"TOPIC", :topic, 32},
    {"ASSIGNEE", :assignee_slug, 16},
    {"RUNTIME_TYPE", :runtime_type, 13},
    {"ONLINE", :runtime_online?, 7},
    {"INERT", :declared_inert_reason, 20}
  ]

  defp header(rows) do
    """
    Responsibility dispatch reachability
    ====================================
    as_of: #{DateTime.to_iso8601(DateTime.utc_now())}
    enabled rows: #{length(rows)}
    """
  end

  defp table(rows) do
    head = Enum.map_join(@columns, "", fn {label, _field, width} -> pad(label, width) end)

    body =
      Enum.map_join(rows, "\n", fn row ->
        Enum.map_join(@columns, "", fn {_label, field, width} ->
          pad(cell(Map.get(row, field)), width)
        end)
      end)

    width = Enum.sum(Enum.map(@columns, fn {_label, _field, w} -> w end))

    Enum.join([String.trim_trailing(head), String.duplicate("-", width), body, ""], "\n")
  end

  defp tally(rows) do
    counts = Enum.frequencies_by(rows, & &1.class)

    lines =
      Enum.map_join(@classes, "\n", fn class ->
        "  #{pad(to_string(class), 18)}#{Map.get(counts, class, 0)}"
      end)

    inert = Enum.count(rows, & &1.declared_inert?)

    """
    class tally
    -----------
    #{lines}

      #{pad("declared_inert?", 18)}#{inert}  (orthogonal to class — see moduledoc)
    """
  end

  defp machine_readable(rows) do
    fields = [
      :key,
      :class,
      :trigger_kind,
      :feature,
      :topic,
      :assignee_slug,
      :assignee_id,
      :runtime_type,
      :runtime_id,
      :runtime_online?,
      :declared_status,
      :declared_executor,
      :declared_inert?,
      :declared_inert_reason
    ]

    body =
      Enum.map_join(rows, "\n", fn row ->
        "REACH " <>
          Enum.map_join(fields, " ", fn field -> "#{field}=#{cell(Map.get(row, field))}" end)
      end)

    Enum.join(["machine-readable", "----------------", body, ""], "\n")
  end

  defp caveat do
    """
    NOTE: `broadcastable` means the SERVER would broadcast. It says nothing about
    whether the receiving client parses the envelope — the 2026-07-27 defect was a
    client reading `payload.message.content` on a payload whose prompt lives at
    `signal.prompt`, and every affected key read `broadcastable` throughout. Delivery
    evidence must come from the receiving runtime's own logs.

    `unfilled` is progressive enhancement, not a failure. `declared_inert?` rows were
    never meant to fire and are not casualties of anything.
    """
  end

  defp cell(nil), do: "-"
  defp cell(value) when is_binary(value), do: value
  defp cell(value), do: to_string(value)

  defp pad(value, width) do
    String.pad_trailing(value, width)
  end
end
