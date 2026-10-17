defmodule Platform.Chat.DispatchMembershipTest do
  @moduledoc """
  Task 019fb90f stage 1 — `Platform.Chat.DispatchMembership`.

  ## What each group of tests would catch

    * **Happy path** — asserts the agent *could not write before* and *can write
      after*, using the real tool-surface refusal as the probe. Without the
      before-half, "it can write after" is equally consistent with "it could
      always write", and the test would pass against a `ensure_writable/3` that
      did nothing at all.
    * **Idempotence** — asserts the row COUNT is exactly 1 and that the
      surviving row's `id`/`joined_at` are unchanged. A `{:ok, _}`-shaped
      assertion would pass against a delete-and-reinsert, a silent update, or a
      genuine duplicate.
    * **Refusals** — one test per atom, each asserting the exact atom AND that
      no participant row appeared. A refactor collapsing (say) `:direct_space`
      and `:space_archived` into a shared `:refused` would still satisfy a
      `{:skip, _}` assertion; it fails these.
    * **Precedence** — which refusal wins when more than one applies. Every
      other refusal test feeds an input that only ONE atom can answer, so all of
      them stay green if the resolution order is swapped. The precedence tests
      feed genuinely ambiguous input and pin the answer.
    * **`:insert_failed` vs `:already_member`** — the two outcomes of a failed
      `Chat.add_agent_participant/3`, separated only by whether a row is
      actually there. Both are driven through the same seam so the tests differ
      in exactly the variable that is supposed to decide it.
    * **Attention mode** — an execution space must yield `"all"` and everything
      else `"mention"`. A single hardcoded default passes one and fails the other.
    * **Telemetry** — every call emits, refusals included. Dropping emission on
      the refusal paths is the failure this catches, and it matters because
      telemetry is the only thing that makes an ADR-0038 resurrection observable.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.DispatchMembership
  alias Platform.Chat.Participant
  alias Platform.Chat.Space
  alias Platform.Federation.ToolSurface
  alias Platform.Repo

  @event [:platform, :chat, :dispatch_auto_invite]

  # ── Builders ───────────────────────────────────────────────────────────────

  defp space!(attrs \\ %{}) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(
        Map.merge(%{name: "DM Test #{n}", slug: "dm-test-#{n}", kind: "channel"}, attrs)
      )

    space
  end

  defp agent!(attrs \\ %{}) do
    n = System.unique_integer([:positive, :monotonic])

    defaults = %{
      slug: "dispatch-target-#{n}",
      name: "Dispatch Target #{n}",
      status: "active",
      max_concurrent: 1,
      sandbox_mode: "off",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    }

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    agent
  end

  # Build the tool context exactly the way `PlatformWeb.MCPController.build_context/2`
  # does for a federated runtime: resolve `agent_participant_id` from the space
  # AT CALL TIME.
  #
  # This is not incidental. `Canvas.ToolHandlers.create/2` reads
  # `context[:agent_participant_id]` and does NOT resolve it from `:agent_id`,
  # so a context of `%{agent_id: agent.id}` alone refuses unconditionally —
  # before the invite and after it. A probe built that way would report the
  # not-a-participant error in both halves of the happy-path test, which reads
  # like a passing negative control while actually proving nothing about
  # membership. Resolving here is what makes the probe sensitive to the thing
  # under test.
  defp mcp_context(space_id, agent_id) do
    participant_id =
      case Chat.get_agent_participant(space_id, agent_id) do
        %Participant{id: id} -> id
        _ -> nil
      end

    %{space_id: space_id, agent_id: agent_id, agent_participant_id: participant_id}
  end

  defp canvas_probe(space_id, agent_id) do
    args = %{
      "space_id" => space_id,
      "title" => "writability probe",
      "document" => %{
        "version" => 1,
        "revision" => 1,
        "root" => %{
          "id" => "root",
          "type" => "text",
          "props" => %{"value" => "probe"},
          "children" => []
        }
      }
    }

    ToolSurface.execute("canvas_create", args, mcp_context(space_id, agent_id))
  end

  defp participant_count(space_id, agent_id) do
    Repo.aggregate(
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "agent" and
            p.participant_id == ^agent_id
      ),
      :count
    )
  end

  defp attach_telemetry do
    ref = make_ref()
    pid = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      @event,
      fn _event, measurements, metadata, _cfg ->
        send(pid, {:auto_invite, ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  # ── Opening the insert window on purpose ───────────────────────────────────
  #
  # `do_invite/3`'s `{:error, reason}` arm has two exits — `:already_member`
  # (a concurrent writer won; a row exists) and `{:insert_failed, reason}` (the
  # write really failed; no row exists) — and nothing on the path is behind a
  # behaviour, so neither can be reached by stubbing. A spawned racer would
  # reach them only sometimes, which is not a test.
  #
  # Instead, hook Ecto's own query telemetry and act *inside* the call. The
  # ordinal is what selects which exit:
  #
  #   1st `chat_participants` query — the module's `get_agent_participant/2`
  #      pre-check, i.e. the top of the window.
  #   2nd — `Chat.do_add_agent_participant/3`'s own find-or-insert lookup, i.e.
  #      after the delegate has already decided the row is absent.
  #
  # Acting at #1 lets the delegate see the change; acting at #2 does not. That
  # single difference is what the two tests below vary, and it is the real
  # production window in both cases.
  defp on_participants_query(n, fun) do
    test_pid = self()
    handler_id = {__MODULE__, :window, make_ref()}
    counter = {__MODULE__, :window_count, handler_id}

    :telemetry.attach(
      handler_id,
      [:platform, :repo, :query],
      fn _event, _measurements, meta, _cfg ->
        # The handler runs in the EMITTING process. Everything the rest of the
        # suite is doing concurrently is discarded here.
        if self() == test_pid and meta[:source] == "chat_participants" do
          seen = (Process.get(counter) || 0) + 1
          Process.put(counter, seen)

          if seen == n do
            # Detach FIRST: `fun` issues its own queries against the same table
            # and would otherwise re-enter this handler.
            :telemetry.detach(handler_id)
            fun.()
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # ── Happy path (with the negative control that makes it mean something) ────

  describe "ensure_writable/3 — invite" do
    test "an agent that could not write the space can write it afterwards" do
      space = space!()
      agent = agent!()

      # NEGATIVE CONTROL. Both halves matter: no row, and the real tool refuses.
      assert Chat.get_agent_participant(space.id, agent.id) == nil

      assert {:error, %{recoverable: false} = err} = canvas_probe(space.id, agent.id)
      assert err.error =~ "is not a participant"

      assert {:ok, :invited} = DispatchMembership.ensure_writable(space.id, agent.id)

      assert %Participant{} = row = Chat.get_agent_participant(space.id, agent.id)
      assert row.participant_type == "agent"
      assert row.role == "member"

      # The byte-identical probe now succeeds. This is the whole claim.
      assert {:ok, %{canvas_id: canvas_id}} = canvas_probe(space.id, agent.id)
      assert is_binary(canvas_id)
      on_exit(fn -> CanvasServer.stop(canvas_id) end)
    end

    test "accepts an agent slug as well as an id" do
      space = space!()
      agent = agent!()

      assert {:ok, :invited} = DispatchMembership.ensure_writable(space.id, agent.slug)
      assert %Participant{} = Chat.get_agent_participant(space.id, agent.id)
    end

    test "display_name defaults to the agent's name and can be overridden" do
      agent = agent!()

      default_space = space!()
      assert {:ok, :invited} = DispatchMembership.ensure_writable(default_space.id, agent.id)
      assert Chat.get_agent_participant(default_space.id, agent.id).display_name == agent.name

      override_space = space!()

      assert {:ok, :invited} =
               DispatchMembership.ensure_writable(override_space.id, agent.id,
                 display_name: "Scribe"
               )

      assert Chat.get_agent_participant(override_space.id, agent.id).display_name == "Scribe"
    end
  end

  # ── Idempotence ────────────────────────────────────────────────────────────

  describe "ensure_writable/3 — idempotence" do
    test "a second call is already_member and leaves exactly one unchanged row" do
      space = space!()
      agent = agent!()

      assert {:ok, :invited} = DispatchMembership.ensure_writable(space.id, agent.id)
      first = Chat.get_agent_participant(space.id, agent.id)

      assert {:ok, :already_member} = DispatchMembership.ensure_writable(space.id, agent.id)
      assert {:ok, :already_member} = DispatchMembership.ensure_writable(space.id, agent.id)

      # Equality with 1, not `>= 1`: a duplicate insert must fail this.
      assert participant_count(space.id, agent.id) == 1

      second = Chat.get_agent_participant(space.id, agent.id)

      # Same id and same joined_at proves find-or-insert rather than
      # delete-and-reinsert (new id) or a silent update (new joined_at).
      assert second.id == first.id
      assert second.joined_at == first.joined_at
      assert second.attention_mode == first.attention_mode
    end

    test "already_member does not depend on how the row got there" do
      space = space!()
      agent = agent!()

      # Row created by the ordinary roster path, not by this module.
      {:ok, _} = Chat.add_agent_participant(space.id, agent, attention_mode: "mention")

      assert {:ok, :already_member} = DispatchMembership.ensure_writable(space.id, agent.id)
      assert participant_count(space.id, agent.id) == 1
    end

    test "an existing row's attention_mode is never rewritten" do
      space = space!(%{kind: "execution", name: "exec idempotence"})
      agent = agent!()

      # Deliberately weaker than the policy would choose for an execution space.
      {:ok, _} = Chat.add_agent_participant(space.id, agent, attention_mode: "mention")

      assert {:ok, :already_member} = DispatchMembership.ensure_writable(space.id, agent.id)

      # If this ever reads "all", the function silently mutated a roster row a
      # human may have deliberately narrowed. It is an invite, not a settings push.
      assert Chat.get_agent_participant(space.id, agent.id).attention_mode == "mention"
    end
  end

  # ── Refusals: one test per atom ────────────────────────────────────────────

  describe "ensure_writable/3 — refusals" do
    test ":no_space_named when the dispatch named no space" do
      agent = agent!()
      assert {:skip, :no_space_named} = DispatchMembership.ensure_writable(nil, agent.id)

      assert Repo.aggregate(from(p in Participant, where: p.participant_id == ^agent.id), :count) ==
               0
    end

    test ":invalid_space_id for a value that is not a UUID" do
      agent = agent!()

      assert {:skip, :invalid_space_id} =
               DispatchMembership.ensure_writable("general", agent.id)

      # A 16-character slug is a 16-byte binary that a bare `Ecto.UUID.cast/1`
      # accepts — the exact input that raises inside Repo if the guard is
      # "simplified" to a bare cast.
      assert {:skip, :invalid_space_id} =
               DispatchMembership.ensure_writable("higginshigginsxx", agent.id)

      assert Repo.aggregate(from(p in Participant, where: p.participant_id == ^agent.id), :count) ==
               0
    end

    test ":space_not_found for a well-formed UUID with no row" do
      agent = agent!()
      missing = Ecto.UUID.generate()

      assert {:skip, :space_not_found} = DispatchMembership.ensure_writable(missing, agent.id)
      assert Chat.get_agent_participant(missing, agent.id) == nil
    end

    test ":space_archived for an archived space" do
      space = space!()
      agent = agent!()
      {:ok, archived} = Chat.archive_space(space)

      assert {:skip, :space_archived} = DispatchMembership.ensure_writable(archived.id, agent.id)
      assert Chat.get_agent_participant(space.id, agent.id) == nil
    end

    test ":direct_space for a dm-kind space" do
      space = space!(%{kind: "dm", name: nil, slug: nil})
      agent = agent!()

      assert {:skip, :direct_space} = DispatchMembership.ensure_writable(space.id, agent.id)
      assert Chat.get_agent_participant(space.id, agent.id) == nil
    end

    test ":direct_space for is_direct even when the kind is not \"dm\"" do
      # The changeset forbids this combination today, which is exactly why the
      # row is inserted directly: the guard must not be reachable ONLY through
      # `kind == "dm"`, or a future direct-ish kind slips past by being spelled
      # differently. Insert bypasses `Space.changeset/2` deliberately.
      space =
        Repo.insert!(%Space{
          kind: "group",
          name: "sneaky direct",
          is_direct: true,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })

      agent = agent!()

      assert {:skip, :direct_space} = DispatchMembership.ensure_writable(space.id, agent.id)
      assert Chat.get_agent_participant(space.id, agent.id) == nil
    end

    test ":direct_space wins over :space_archived for an archived DM" do
      # Precedence is asserted, not left to chance: a DM must never report as
      # merely archived, because the privacy refusal is the policy statement
      # and it should not be masked by lifecycle state.
      space = space!(%{kind: "dm", name: nil, slug: nil})
      {:ok, archived} = Chat.archive_space(space)
      agent = agent!()

      assert {:skip, :direct_space} = DispatchMembership.ensure_writable(archived.id, agent.id)
    end

    test ":no_agent_named when the dispatch named no agent" do
      space = space!()

      # `create_space/1` auto-attaches the Historian, so an absolute count of 0
      # would be wrong here and a `<= 1` would be too loose to notice a stray
      # insert. Compare the roster before and after instead.
      before = space.id |> Chat.list_participants() |> Enum.map(& &1.id) |> Enum.sort()

      assert {:skip, :no_agent_named} = DispatchMembership.ensure_writable(space.id, nil)

      assert space.id |> Chat.list_participants() |> Enum.map(& &1.id) |> Enum.sort() == before
    end

    test ":agent_not_found for an unresolvable agent reference" do
      space = space!()
      missing_uuid = Ecto.UUID.generate()

      assert {:skip, :agent_not_found} =
               DispatchMembership.ensure_writable(space.id, missing_uuid)

      assert {:skip, :agent_not_found} =
               DispatchMembership.ensure_writable(space.id, "no-such-agent-slug")

      assert Chat.get_agent_participant(space.id, missing_uuid) == nil
    end

    test ":insert_failed when the write really fails and no row appears" do
      ref = attach_telemetry()
      space = space!()
      agent = agent!()

      # Archive the space after this module has loaded and approved it, but
      # before `Chat.add_participant/2` re-checks writability. The delegate
      # then refuses with {:error, :space_archived} and — the part that matters
      # — nobody won a race, so the re-lookup finds nothing.
      on_participants_query(1, fn ->
        Repo.update_all(from(s in Space, where: s.id == ^space.id),
          set: [archived_at: DateTime.utc_now()]
        )
      end)

      assert {:skip, {:insert_failed, reason}} =
               DispatchMembership.ensure_writable(space.id, agent.id, source: :task_router)

      assert reason == :space_archived

      # This half is what makes the atom non-vacuous. `{:ok, :already_member}`
      # here would be a failed write reported as a success — the caller would
      # believe the agent can write a space it cannot write, and nothing
      # downstream would say otherwise.
      assert Chat.get_agent_participant(space.id, agent.id) == nil
      assert participant_count(space.id, agent.id) == 0

      assert_receive {:auto_invite, ^ref, %{count: 1}, meta}
      assert meta.outcome == :insert_failed
      assert meta.detail == :space_archived
      assert meta.source == :task_router
    end

    test "a lost insert race is :already_member, not :insert_failed" do
      # Negative control for the test above, through the SAME seam one query
      # later: the delegate's own find-or-insert lookup has already returned
      # nil, so its insert hits the uniqueness constraint and errors — but the
      # row IS there. If the re-lookup were deleted and the {:error, _} arm went
      # straight to :insert_failed, this test is the one that notices.
      space = space!()
      agent = agent!()

      on_participants_query(2, fn ->
        {:ok, _} = Chat.add_agent_participant(space.id, agent, attention_mode: "mention")
      end)

      assert {:ok, :already_member} = DispatchMembership.ensure_writable(space.id, agent.id)

      # Exactly one row: the racer's. Reporting success while leaving two rows,
      # or while leaving none, are both failures this catches.
      assert participant_count(space.id, agent.id) == 1
    end

    test "every refusal atom is distinct" do
      # The point of the module. If two of these ever collapse, an operator
      # cannot tell a deleted space from an archived one from a dispatch that
      # named none, and this assertion is the thing that says so out loud.
      space = space!()
      dm = space!(%{kind: "dm", name: nil, slug: nil})
      archived_space = space!()
      {:ok, archived} = Chat.archive_space(archived_space)
      doomed = space!()
      agent = agent!()

      # Attached last so the query counter only sees the final call; none of the
      # seven refusals above reaches `chat_participants` at all.
      on_participants_query(1, fn ->
        Repo.update_all(from(s in Space, where: s.id == ^doomed.id),
          set: [archived_at: DateTime.utc_now()]
        )
      end)

      outcomes = [
        DispatchMembership.ensure_writable(nil, agent.id),
        DispatchMembership.ensure_writable("general", agent.id),
        DispatchMembership.ensure_writable(Ecto.UUID.generate(), agent.id),
        DispatchMembership.ensure_writable(archived.id, agent.id),
        DispatchMembership.ensure_writable(dm.id, agent.id),
        DispatchMembership.ensure_writable(space.id, nil),
        DispatchMembership.ensure_writable(space.id, Ecto.UUID.generate()),
        DispatchMembership.ensure_writable(doomed.id, agent.id)
      ]

      reasons = Enum.map(outcomes, fn {:skip, reason} -> reason end)

      assert [
               :no_space_named,
               :invalid_space_id,
               :space_not_found,
               :space_archived,
               :direct_space,
               :no_agent_named,
               :agent_not_found,
               {:insert_failed, _}
             ] = reasons

      # Distinctness has to hold on the LEADING atom, not the whole term:
      # that atom is what `emit/5` puts on telemetry as `:outcome` and what any
      # aggregator groups by. A compound reason whose head duplicated one of the
      # bare ones would look distinct here and be indistinguishable in a
      # dashboard.
      outcome_atoms =
        Enum.map(reasons, fn
          reason when is_atom(reason) -> reason
          {reason, _detail} when is_atom(reason) -> reason
        end)

      assert length(Enum.uniq(outcome_atoms)) == 8
    end
  end

  # ── Precedence: which refusal wins when several apply ──────────────────────

  describe "ensure_writable/3 — refusal precedence" do
    test "space-shaped refusals are evaluated before agent-shaped ones" do
      # Every other refusal test feeds input that only one atom can answer, so
      # all of them stay green if `resolve_and_invite/3`'s two `case` levels are
      # swapped. This one feeds genuinely ambiguous input: nothing was named on
      # either side, so the answer is a decision rather than a fact, and without
      # a test it is only a comment.
      assert {:skip, :no_space_named} = DispatchMembership.ensure_writable(nil, nil)

      # And it is a rule about the whole family, not a nil/nil special case: a
      # missing agent never wins while the space half still has something to
      # say. Space is what the dispatch NAMED — it is the scope the policy is
      # defined against, and it has to be repaired first.
      assert {:skip, :invalid_space_id} = DispatchMembership.ensure_writable("general", nil)

      assert {:skip, :space_not_found} =
               DispatchMembership.ensure_writable(Ecto.UUID.generate(), nil)

      dm = space!(%{kind: "dm", name: nil, slug: nil})
      assert {:skip, :direct_space} = DispatchMembership.ensure_writable(dm.id, nil)

      {:ok, archived} = Chat.archive_space(space!())
      assert {:skip, :space_archived} = DispatchMembership.ensure_writable(archived.id, nil)
    end

    test "the ambiguous call reports its precedence choice on telemetry too" do
      # The atom an operator is paged with is the telemetry one, so the
      # precedence decision has to survive the trip through `emit/5`.
      ref = attach_telemetry()

      assert {:skip, :no_space_named} =
               DispatchMembership.ensure_writable(nil, nil, source: :meeting_triage)

      assert_receive {:auto_invite, ^ref, %{count: 1}, meta}
      assert meta.outcome == :no_space_named
      assert meta.space_id == nil
      assert meta.agent_id == nil
      assert meta.space_kind == nil
      assert meta.source == :meeting_triage
    end
  end

  # ── Attention mode by space kind ───────────────────────────────────────────

  describe "ensure_writable/3 — attention mode" do
    test "an execution space yields \"all\"" do
      space = space!(%{kind: "execution", name: "Task exec space"})
      agent = agent!()

      assert {:ok, :invited} = DispatchMembership.ensure_writable(space.id, agent.id)

      # "all", not "mention": TaskRouter engagement messages do not @-mention
      # the assignee, so a "mention" row would leave it deaf to its own task.
      assert Chat.get_agent_participant(space.id, agent.id).attention_mode == "all"
    end

    test "a meeting space yields \"mention\"" do
      space = space!(%{kind: "meeting", name: "Standup", slug: nil})
      agent = agent!()

      assert {:ok, :invited} = DispatchMembership.ensure_writable(space.id, agent.id)
      assert Chat.get_agent_participant(space.id, agent.id).attention_mode == "mention"
    end

    test "a channel yields \"mention\"" do
      space = space!()
      agent = agent!()

      assert {:ok, :invited} = DispatchMembership.ensure_writable(space.id, agent.id)
      assert Chat.get_agent_participant(space.id, agent.id).attention_mode == "mention"
    end
  end

  # ── Telemetry ──────────────────────────────────────────────────────────────

  describe "ensure_writable/3 — telemetry" do
    test "an invite emits with the source, the space kind, and outcome :invited" do
      ref = attach_telemetry()
      space = space!(%{kind: "execution", name: "Telemetry exec"})
      agent = agent!()

      assert {:ok, :invited} =
               DispatchMembership.ensure_writable(space.id, agent.id, source: :task_router)

      assert_receive {:auto_invite, ^ref, %{count: 1}, meta}
      assert meta.outcome == :invited
      assert meta.space_id == space.id
      assert meta.agent_id == agent.id
      assert meta.space_kind == "execution"
      assert meta.source == :task_router
    end

    test "a repeat call emits outcome :already_member" do
      ref = attach_telemetry()
      space = space!()
      agent = agent!()

      assert {:ok, :invited} =
               DispatchMembership.ensure_writable(space.id, agent.id, source: :meeting_scribe)

      assert_receive {:auto_invite, ^ref, _, %{outcome: :invited}}

      assert {:ok, :already_member} =
               DispatchMembership.ensure_writable(space.id, agent.id, source: :meeting_scribe)

      assert_receive {:auto_invite, ^ref, _, %{outcome: :already_member, source: :meeting_scribe}}
    end

    test "refusals emit too, carrying the specific reason as the outcome" do
      # This is the resurrection-observability contract from the moduledoc. If
      # emission were moved inside the success branch, an operator would see
      # nothing at all for a dispatch that silently could not confer writability.
      ref = attach_telemetry()
      dm = space!(%{kind: "dm", name: nil, slug: nil})
      agent = agent!()

      assert {:skip, :direct_space} =
               DispatchMembership.ensure_writable(dm.id, agent.id, source: :meeting_intent)

      assert_receive {:auto_invite, ^ref, %{count: 1}, meta}
      assert meta.outcome == :direct_space
      assert meta.space_kind == "dm"
      assert meta.source == :meeting_intent

      assert {:skip, :no_space_named} =
               DispatchMembership.ensure_writable(nil, agent.id, source: :agent_responder)

      assert_receive {:auto_invite, ^ref, %{count: 1}, nil_meta}
      assert nil_meta.outcome == :no_space_named
      assert nil_meta.space_kind == nil
      assert nil_meta.space_id == nil
    end

    test "source defaults to nil rather than being omitted" do
      ref = attach_telemetry()
      space = space!()
      agent = agent!()

      assert {:ok, :invited} = DispatchMembership.ensure_writable(space.id, agent.id)

      assert_receive {:auto_invite, ^ref, _, meta}
      assert Map.has_key?(meta, :source)
      assert meta.source == nil
    end
  end

  # ── Never raises ───────────────────────────────────────────────────────────

  describe "ensure_writable/3 — raise safety" do
    test "a non-binary space or agent is refused, not raised" do
      agent = agent!()
      space = space!()

      assert {:skip, :invalid_space_id} = DispatchMembership.ensure_writable(123, agent.id)
      assert {:skip, :invalid_space_id} = DispatchMembership.ensure_writable(%{}, agent.id)
      assert {:skip, :agent_not_found} = DispatchMembership.ensure_writable(space.id, 123)
    end

    test "an exception inside the invite becomes {:skip, {:raised, msg}} and still emits" do
      # Negative control for the try/rescue: force a real raise from inside the
      # body by handing the resolver an Agent struct with a malformed id, which
      # blows up in Repo on the participant lookup. Asserting only "it returns a
      # tuple" would pass even with the rescue deleted, since most inputs never
      # raise — this input does.
      ref = attach_telemetry()
      space = space!()
      broken = %Agent{id: "not-a-uuid", name: "Broken", slug: "broken"}

      assert {:skip, {:raised, msg}} = DispatchMembership.ensure_writable(space.id, broken)
      assert is_binary(msg)

      assert_receive {:auto_invite, ^ref, %{count: 1}, meta}
      assert meta.outcome == :raised
      assert meta.detail == msg
    end
  end
end
