defmodule Platform.Federation.DeadLetterReplayTest do
  # `async: false` on purpose. The drain runs inside the singleton
  # `DeadLetterReplay` GenServer, which is a SHARED supervised process: under
  # `async: true` it would have to be `Sandbox.allow`ed onto this test's
  # connection, and two concurrent async tests allowing the same pid onto
  # different connections is a race, not a test. Shared sandbox mode
  # (DataCase's `not tags[:async]` branch) lets the server use this test's
  # connection without any per-pid allowance.
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat.AgentResponder
  alias Platform.Federation.DeadLetter
  alias Platform.Federation.DeadLetterReplay
  alias Platform.Federation.DeadLetters
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo
  alias Platform.Tasks

  setup do
    runtime_pres = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    Sandbox.allow(Repo, self(), runtime_pres)
    :ok
  end

  # ── Fixtures ─────────────────────────────────────────────────────────

  defp offline_runtime(prefix) do
    suffix = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "dlr-#{prefix}-#{suffix}@example.com",
        name: "DLR Owner #{suffix}",
        oidc_sub: "oidc-dlr-#{prefix}-#{suffix}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-dlr-#{prefix}-#{suffix}",
        display_name: "dlr-runtime-#{suffix}"
      })

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "dlr-#{prefix}-#{suffix}",
        name: "DLR Agent #{suffix}",
        status: "active",
        runtime_type: "external",
        runtime_id: runtime.id
      })
      |> Repo.insert!()

    # NEVER tracked here. The whole point of a dead letter is a runtime that
    # was genuinely absent from presence when the fire went out.
    refute RuntimePresence.online?(runtime.runtime_id)
    on_exit(fn -> RuntimePresence.untrack(runtime.runtime_id) end)

    %{runtime: runtime, agent: agent, owner: owner, topic: "runtime:#{runtime.runtime_id}"}
  end

  # A task + approved plan + one `passed` stage: the exact subject shape
  # `DeadLetterPolicy.audit_diff_freshness/1` rules on.
  defp fresh_subject(name \\ "Replay") do
    suffix = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "#{name} Project #{suffix}"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "#{name} Task #{suffix}"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build", status: "passed"})

    %{project: project, task: task, plan: plan, stage: stage}
  end

  # Drive the REAL producer. Nothing in this file hand-writes a system_event
  # row: a fixture row would let the ledger and the wire drift apart, which is
  # precisely the defect stage 1 was written to close.
  defp dead_letter_via_responder(%{runtime: runtime, agent: agent}, metadata) do
    signal =
      %{
        reason: :system_event,
        metadata:
          Map.merge(
            %{
              feature: "architecture",
              agent_id: agent.id,
              agent_slug: agent.slug,
              responsibility_key: "architecture.audit_diff",
              trigger_kind: :event_topic
            },
            metadata
          )
      }

    assert {:error, :runtime_offline} = AgentResponder.respond(signal)

    # The newest row for this runtime is the one that call just wrote — or,
    # when `record/1`'s unique index collapsed a duplicate, the row it
    # collapsed into, which is exactly what the caller wants to inspect.
    Repo.one!(
      from(d in DeadLetter,
        where: d.runtime_id == ^runtime.runtime_id,
        order_by: [desc: d.inserted_at, desc: d.id],
        limit: 1
      )
    )
  end

  defp stage_metadata(%{task: task, plan: plan, stage: stage}, overrides \\ %{}) do
    Map.merge(
      %{task_id: task.id, plan_id: plan.id, stage_id: stage.id},
      overrides
    )
  end

  defp reload(%DeadLetter{id: id}), do: Repo.get!(DeadLetter, id)

  # ── End-to-end fidelity ──────────────────────────────────────────────

  describe "replay_now/2 end to end" do
    test "a genuinely dead-lettered fire is delivered with its envelope intact" do
      ctx = offline_runtime("e2e")
      subject = fresh_subject()

      row = dead_letter_via_responder(ctx, stage_metadata(subject))

      # Pin the PRE-state. Without this the assertions below could pass on a
      # replay of something that was never captured in the first place.
      assert row.disposition == "pending"
      assert row.source == "system_event"
      assert row.responsibility_key == "architecture.audit_diff"
      assert row.subject_type == "stage"
      assert row.subject_id == subject.stage.id
      assert row.payload["signal"]["metadata"]["stage_id"] == subject.stage.id
      assert row.attempts == 0

      :ok = PlatformWeb.Endpoint.subscribe(ctx.topic)
      RuntimePresence.track(ctx.runtime.runtime_id)

      assert {:ok, summary} =
               DeadLetterReplay.replay_now(ctx.runtime.runtime_id, spacing_ms: 0)

      assert summary.delivered == 1
      assert summary.dropped == 0
      assert summary.aborted == false

      topic = ctx.topic

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^topic,
                       event: "attention",
                       payload: %{signal: signal}
                     },
                     2000

      # The jsonb round-trip is the hazard: these came back out of Postgres as
      # strings and must be atoms again on the wire, or the bridge's `case`
      # clauses silently stop matching.
      assert signal.reason == :system_event
      assert signal.trigger_kind == :event_topic
      assert signal.responsibility_key == "architecture.audit_diff"
      assert signal.agent_id == ctx.agent.id
      assert signal.agent_slug == ctx.agent.slug
      assert signal.metadata.stage_id == subject.stage.id
      assert signal.metadata.plan_id == subject.plan.id
      assert signal.metadata.task_id == subject.task.id

      replayed = reload(row)
      assert replayed.disposition == "replayed"
      assert replayed.attempts == 1
      assert replayed.dispositioned_at
    end

    test "an offline runtime is not drained at all — no row is touched" do
      ctx = offline_runtime("offline")
      subject = fresh_subject()
      row = dead_letter_via_responder(ctx, stage_metadata(subject))

      assert {:ok, %{skipped: :offline}} =
               DeadLetterReplay.replay_now(ctx.runtime.runtime_id, spacing_ms: 0)

      untouched = reload(row)
      assert untouched.disposition == "pending"
      assert untouched.attempts == 0

      # Positive twin: the SAME row, the SAME call, presence flipped. Without
      # this the assertions above would hold for a replay_now/2 that did
      # nothing at all, ever.
      :ok = PlatformWeb.Endpoint.subscribe(ctx.topic)
      RuntimePresence.track(ctx.runtime.runtime_id)

      assert {:ok, %{delivered: 1}} =
               DeadLetterReplay.replay_now(ctx.runtime.runtime_id, spacing_ms: 0)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2000
      assert reload(row).disposition == "replayed"
    end
  end

  # ── Policy drops, each with a positive control ───────────────────────

  describe "drops" do
    test "cron is dropped while a fresh audit_diff for the SAME runtime delivers" do
      ctx = offline_runtime("cron")
      subject = fresh_subject()

      cron_row =
        dead_letter_via_responder(ctx, %{
          feature: "memory",
          responsibility_key: "memory.dreaming",
          trigger_kind: :cron
        })

      audit_row = dead_letter_via_responder(ctx, stage_metadata(subject))

      assert cron_row.trigger_kind == "cron"
      assert cron_row.disposition == "pending"
      assert audit_row.disposition == "pending"

      :ok = PlatformWeb.Endpoint.subscribe(ctx.topic)
      RuntimePresence.track(ctx.runtime.runtime_id)

      assert {:ok, summary} =
               DeadLetterReplay.replay_now(ctx.runtime.runtime_id, spacing_ms: 0)

      assert summary.delivered == 1
      assert summary.dropped == 1

      # THE POSITIVE CONTROL. An absent cron frame means nothing unless the
      # same channel demonstrably delivered something else in the same drain.
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: delivered}
                     },
                     2000

      assert delivered.responsibility_key == "architecture.audit_diff"
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 200

      dropped = reload(cron_row)
      assert dropped.disposition == "dropped_policy"
      assert dropped.reason == "stale_by_wall_clock"
      # A refused KIND was never attempted, so the delivery counter must not move.
      assert dropped.attempts == 0
      assert dropped.dispositioned_at

      assert reload(audit_row).disposition == "replayed"
    end

    test "a superseded subject lands dropped_stale while its fresh sibling delivers" do
      ctx = offline_runtime("stale")
      stale = fresh_subject("Stale")
      fresh = fresh_subject("Fresh")

      stale_row = dead_letter_via_responder(ctx, stage_metadata(stale))
      fresh_row = dead_letter_via_responder(ctx, stage_metadata(fresh))

      # Real supersession: a second plan version for the same task makes the
      # first plan's stage no longer current.
      {:ok, v2} = Tasks.create_plan(%{task_id: stale.task.id, status: "approved"})
      assert v2.version == stale.plan.version + 1
      assert Tasks.current_plan(stale.task.id).id == v2.id

      :ok = PlatformWeb.Endpoint.subscribe(ctx.topic)
      RuntimePresence.track(ctx.runtime.runtime_id)

      assert {:ok, %{delivered: 1, dropped: 1}} =
               DeadLetterReplay.replay_now(ctx.runtime.runtime_id, spacing_ms: 0)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{signal: delivered}
                     },
                     2000

      assert delivered.metadata.stage_id == fresh.stage.id
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 200

      dropped = reload(stale_row)
      assert dropped.disposition == "dropped_stale"
      assert dropped.reason == "subject_superseded"
      assert reload(fresh_row).disposition == "replayed"
    end

    test "a row past the attempt limit is abandoned, and does not stop the drain" do
      ctx = offline_runtime("attempts")
      spent = fresh_subject("Spent")
      good = fresh_subject("Good")

      spent_row = dead_letter_via_responder(ctx, stage_metadata(spent))
      good_row = dead_letter_via_responder(ctx, stage_metadata(good))

      {1, _} =
        from(d in DeadLetter, where: d.id == ^spent_row.id)
        |> Repo.update_all(set: [attempts: 3])

      :ok = PlatformWeb.Endpoint.subscribe(ctx.topic)
      RuntimePresence.track(ctx.runtime.runtime_id)

      assert {:ok, %{delivered: 1, abandoned: 1}} =
               DeadLetterReplay.replay_now(ctx.runtime.runtime_id, spacing_ms: 0)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2000

      abandoned = reload(spent_row)
      assert abandoned.disposition == "abandoned"
      assert abandoned.attempts == 3
      assert reload(good_row).disposition == "replayed"
    end
  end

  # ── The two properties this stage exists for ─────────────────────────

  describe "thundering herd" do
    test "at most 25 are delivered per drain and the overflow stays pending" do
      ctx = offline_runtime("herd")
      subject = fresh_subject("Herd")

      # 30 distinct stages on ONE current plan: 30 distinct subjects, all
      # fresh, all for the same runtime — the measured production shape (34
      # pending fires for one runtime in a day).
      rows =
        for position <- 1..30 do
          {:ok, stage} =
            Tasks.create_stage(%{
              plan_id: subject.plan.id,
              position: position,
              name: "Stage #{position}",
              status: "passed"
            })

          dead_letter_via_responder(ctx, stage_metadata(%{subject | stage: stage}))
        end

      assert length(rows) == 30
      assert pending_count(ctx) == 30

      :ok = PlatformWeb.Endpoint.subscribe(ctx.topic)
      RuntimePresence.track(ctx.runtime.runtime_id)

      assert {:ok, summary} =
               DeadLetterReplay.replay_now(ctx.runtime.runtime_id, spacing_ms: 0)

      assert summary.delivered == 25
      assert summary.aborted == false
      assert count_with(ctx, "replayed") == 25
      assert pending_count(ctx) == 5

      # Bounded latency, not loss: the overflow is untouched and drains next
      # reconnect.
      assert Enum.all?(Repo.all(runtime_rows(ctx)), &(&1.attempts <= 1))

      assert {:ok, %{delivered: 5}} =
               DeadLetterReplay.replay_now(ctx.runtime.runtime_id, spacing_ms: 0)

      assert count_with(ctx, "replayed") == 30
      assert pending_count(ctx) == 0
    end

    test "deliveries are spaced by @spacing_ms by default" do
      ctx = offline_runtime("spacing")
      subject = fresh_subject("Spacing")

      for position <- 1..2 do
        {:ok, stage} =
          Tasks.create_stage(%{
            plan_id: subject.plan.id,
            position: position,
            name: "Stage #{position}",
            status: "passed"
          })

        dead_letter_via_responder(ctx, stage_metadata(%{subject | stage: stage}))
      end

      RuntimePresence.track(ctx.runtime.runtime_id)

      {micros, {:ok, summary}} =
        :timer.tc(fn -> DeadLetterReplay.replay_now(ctx.runtime.runtime_id) end)

      assert summary.delivered == 2
      # One gap between two deliveries. Asserting the wall clock rather than
      # the constant is the only way to catch a spacing that is configured but
      # never applied.
      assert div(micros, 1000) >= DeadLetterReplay.spacing_ms()
    end
  end

  describe "the loop guard" do
    test "a mid-drain disconnect aborts, leaves rows pending, and mints NO new row" do
      ctx = offline_runtime("abort")
      subject = fresh_subject("Abort")

      for position <- 1..4 do
        {:ok, stage} =
          Tasks.create_stage(%{
            plan_id: subject.plan.id,
            position: position,
            name: "Stage #{position}",
            status: "passed"
          })

        dead_letter_via_responder(ctx, stage_metadata(%{subject | stage: stage}))
      end

      before_count = Repo.aggregate(DeadLetter, :count)
      assert before_count >= 4

      :ok = PlatformWeb.Endpoint.subscribe(ctx.topic)
      RuntimePresence.track(ctx.runtime.runtime_id)

      # A watcher that pulls the runtime out of presence the instant the first
      # frame lands. With the default 250ms spacing the drain's pre-delivery
      # re-check for row 2 happens well after the untrack.
      test_pid = self()
      topic = ctx.topic
      runtime_id = ctx.runtime.runtime_id

      _watcher =
        spawn_link(fn ->
          :ok = PlatformWeb.Endpoint.subscribe(topic)
          send(test_pid, :watching)

          receive do
            %Phoenix.Socket.Broadcast{event: "attention"} ->
              RuntimePresence.untrack(runtime_id)
              send(test_pid, :untracked)
          after
            5000 -> send(test_pid, :watcher_timeout)
          end
        end)

      assert_receive :watching, 1000

      assert {:ok, summary} = DeadLetterReplay.replay_now(runtime_id)

      assert_receive :untracked, 5000

      # The positive half: one row DID go out before the disconnect.
      assert summary.delivered == 1
      assert summary.aborted == true
      assert count_with(ctx, "replayed") == 1

      # The guard itself. A failed replay must never call DeadLetters.record/1
      # — if it did, this count would grow on every abort and the queue would
      # never converge.
      assert Repo.aggregate(DeadLetter, :count) == before_count

      remaining = Repo.all(from(d in runtime_rows(ctx), where: d.disposition != "replayed"))
      assert length(remaining) == 3
      assert Enum.all?(remaining, &(&1.disposition == "pending"))
      refute Enum.any?(remaining, &(&1.disposition == "abandoned"))
      # Exactly one of them was claimed and reverted; the untouched two are
      # still at zero.
      assert Enum.count(remaining, &(&1.attempts == 1)) == 1
      assert Enum.all?(remaining, &(&1.attempts <= 1))
      # The reverted claim is back in the queue with no decision recorded
      # against it — a pending row carrying a dispositioned_at would assert a
      # ruling that was explicitly un-made.
      assert Enum.all?(remaining, &is_nil(&1.dispositioned_at))
      assert Enum.any?(remaining, &(&1.last_error && &1.last_error =~ "left presence"))
    end

    test "a repeated schedule for the same runtime does not double-deliver" do
      ctx = offline_runtime("dupe-drain")
      subject = fresh_subject("DupeDrain")
      row = dead_letter_via_responder(ctx, stage_metadata(subject))

      :ok = PlatformWeb.Endpoint.subscribe(ctx.topic)
      RuntimePresence.track(ctx.runtime.runtime_id)

      :ok = DeadLetterReplay.schedule(ctx.runtime.runtime_id)
      :ok = DeadLetterReplay.schedule(ctx.runtime.runtime_id)
      # A sync call behind the two casts: the mailbox is FIFO, so this returns
      # only once both drains have run.
      assert DeadLetterReplay.drain_count(ctx.runtime.runtime_id) == 2

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2000
      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300

      replayed = reload(row)
      assert replayed.disposition == "replayed"
      assert replayed.attempts == 1
    end
  end

  # ── The ledger invariant that makes a collapse pass unreachable ──────

  describe "duplicate pending fires" do
    test "the same {runtime, key, subject} cannot queue twice — the DB refuses it" do
      ctx = offline_runtime("dupe")
      subject = fresh_subject("Dupe")
      metadata = stage_metadata(subject)

      row = dead_letter_via_responder(ctx, metadata)
      same = dead_letter_via_responder(ctx, metadata)

      # `record/1`'s partial unique index collapsed the second fire into the
      # first, so the drain never sees two pending rows for one subject and
      # has nothing to collapse. If this ever returns 2, the drain needs the
      # `superseded_duplicate` pass the plan describes.
      assert same.id == row.id
      assert pending_count(ctx) == 1
    end

    test "two subject-less cron fires BOTH stay countable as policy drops" do
      ctx = offline_runtime("cron-pair")

      first =
        dead_letter_via_responder(ctx, %{
          feature: "memory",
          responsibility_key: "memory.dreaming",
          trigger_kind: :cron
        })

      # The ledger's unique index deliberately excludes subject-less rows, so
      # these two coexist. Collapsing them in the drain would replace an
      # informative `stale_by_wall_clock` with `superseded_duplicate` and lose
      # one of the two facts.
      second =
        Repo.insert!(%DeadLetter{
          runtime_id: ctx.runtime.runtime_id,
          runtime_pk: ctx.runtime.id,
          agent_id: ctx.agent.id,
          agent_slug: ctx.agent.slug,
          source: "system_event",
          responsibility_key: "memory.dreaming",
          feature: "memory",
          trigger_kind: "cron",
          payload: first.payload,
          reason: "runtime_offline",
          disposition: "pending",
          occurred_at: DateTime.utc_now()
        })

      assert pending_count(ctx) == 2

      RuntimePresence.track(ctx.runtime.runtime_id)
      assert {:ok, %{dropped: 2}} = DeadLetterReplay.replay_now(ctx.runtime.runtime_id)

      for row <- [first, second] do
        reloaded = reload(row)
        assert reloaded.disposition == "dropped_policy"
        assert reloaded.reason == "stale_by_wall_clock"
      end
    end
  end

  # ── Housekeeping ────────────────────────────────────────────────────

  describe "periodic prune" do
    test "deletes aged terminal rows and never the live queue" do
      ctx = offline_runtime("prune")
      subject = fresh_subject("Prune")
      pending = dead_letter_via_responder(ctx, stage_metadata(subject))

      old = DateTime.add(DateTime.utc_now(), -60 * 86_400, :second)

      {1, _} =
        from(d in DeadLetter, where: d.id == ^pending.id)
        |> Repo.update_all(set: [occurred_at: old])

      terminal =
        Repo.insert!(%DeadLetter{
          runtime_id: ctx.runtime.runtime_id,
          source: "system_event",
          responsibility_key: "architecture.audit_diff",
          trigger_kind: "event_topic",
          disposition: "replayed",
          reason: "replayed",
          occurred_at: old,
          dispositioned_at: old
        })

      send(Process.whereis(DeadLetterReplay), :prune)
      # Flush the mailbox behind the :prune message.
      _ = DeadLetterReplay.drain_count(ctx.runtime.runtime_id)

      refute Repo.get(DeadLetter, terminal.id)
      # Aged, but still the replay queue. A cleanup timer that ate this would
      # become the loss it was meant to bound.
      assert Repo.get(DeadLetter, pending.id)
    end
  end

  describe "daily rollup" do
    test "the :rollup timer logs the cumulative operator line" do
      ctx = offline_runtime("rollup")
      _row = dead_letter_via_responder(ctx, stage_metadata(fresh_subject("Rollup")))

      # `config/test.exs` pins the logger at `:warning`, so an info line is not
      # emitted at all — `capture_log(level: :info)` alone captures nothing.
      # Same dance as `Platform.Security.SweeperTest`.
      prev_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: prev_level) end)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          send(Process.whereis(DeadLetterReplay), :rollup)
          # Flush the mailbox behind the :rollup message.
          _ = DeadLetterReplay.drain_count(ctx.runtime.runtime_id)
        end)

      assert log =~ "[DeadLetters] cumulative"
      assert log =~ "recorded=1"
      assert log =~ "pending=1"
      assert log =~ "top_key=architecture.audit_diff"
      # The label is load-bearing. A reader who mistakes this for a window
      # repeats the 2026-07-27 error in a new place.
      assert log =~ "since inception"
    end
  end

  # ── The accounting invariant, over a REAL drain ──────────────────────

  describe "cumulative counters after a mixed drain" do
    test "recorded == replayed + dropped + superseded + abandoned + pending" do
      ctx = offline_runtime("counters")
      subject = fresh_subject("Counters")
      metadata = stage_metadata(subject)

      # Two fires about the SAME stage. The ledger collapses them; the counter
      # must not — that is the whole argument for a separate table.
      row = dead_letter_via_responder(ctx, metadata)
      same = dead_letter_via_responder(ctx, metadata)
      assert same.id == row.id

      # A cron fire the policy will refuse.
      dead_letter_via_responder(ctx, %{
        feature: "memory",
        responsibility_key: "memory.dreaming",
        trigger_kind: :cron
      })

      # Before the drain: three losses, one of which the ledger folded away.
      # A `SELECT count(*)` over `federation_dead_letters` reads 2 here.
      before = DeadLetters.loss_summary()
      assert before.recorded == 3
      assert before.superseded_duplicate == 1
      assert before.pending == 2
      assert before.balanced

      RuntimePresence.track(ctx.runtime.runtime_id)

      assert {:ok, %{delivered: 1, dropped: 1}} =
               DeadLetterReplay.replay_now(ctx.runtime.runtime_id)

      summary = DeadLetters.loss_summary()

      assert summary.recorded == 3
      assert summary.replayed == 1
      assert summary.dropped_policy == 1
      assert summary.superseded_duplicate == 1
      assert summary.pending == 0

      assert summary.recorded ==
               summary.replayed + summary.dropped_policy + summary.dropped_stale +
                 summary.superseded_duplicate + summary.abandoned + summary.pending

      assert summary.balanced

      # The drain claimed the delivered row (`pending` -> `replaying` ->
      # `replayed`). Neither live disposition may have minted a counter, or
      # every flapping runtime would inflate the totals.
      totals = DeadLetters.counter_totals()
      refute Map.has_key?(totals, "pending")
      refute Map.has_key?(totals, "replaying")
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp runtime_rows(%{runtime: runtime}) do
    from(d in DeadLetter, where: d.runtime_id == ^runtime.runtime_id)
  end

  defp pending_count(ctx), do: count_with(ctx, "pending")

  defp count_with(ctx, disposition) do
    ctx
    |> runtime_rows()
    |> where([d], d.disposition == ^disposition)
    |> Repo.aggregate(:count)
  end
end
