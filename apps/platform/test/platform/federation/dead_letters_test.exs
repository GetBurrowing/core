defmodule Platform.Federation.DeadLettersTest do
  use Platform.DataCase, async: false

  alias Platform.Federation.DeadLetter
  alias Platform.Federation.DeadLetters
  alias Platform.Repo

  # `Platform.DataCase` doesn't ship an `errors_on/1`; every test file that
  # needs one defines it locally (see roles/role_test.exs:24).
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # A representative `architecture.audit_diff` envelope — the exact shape
  # `AgentResponder.build_system_event_signal/2` produces for the fire class
  # that accounted for 34 of the 39 losses on 2026-07-27. Atom-valued
  # `:reason` and `:trigger_kind` are the jsonb round-trip hazard.
  defp audit_diff_envelope(opts \\ []) do
    stage_id = Keyword.get(opts, :stage_id, Ecto.UUID.generate())
    plan_id = Keyword.get(opts, :plan_id, Ecto.UUID.generate())
    task_id = Keyword.get(opts, :task_id, Ecto.UUID.generate())
    agent_id = Keyword.get(opts, :agent_id, Ecto.UUID.generate())

    %{
      signal: %{
        reason: :system_event,
        agent_id: agent_id,
        agent_slug: "moore",
        responsibility_key: "architecture.audit_diff",
        feature: "architecture",
        trigger_kind: :event_topic,
        prompt: "Audit the diff for stage #{stage_id}.",
        metadata: %{
          responsibility_key: "architecture.audit_diff",
          feature: "architecture",
          trigger_kind: :event_topic,
          agent_id: agent_id,
          agent_slug: "moore",
          task_id: task_id,
          plan_id: plan_id,
          stage_id: stage_id
        }
      }
    }
  end

  defp base_attrs(envelope, overrides \\ %{}) do
    signal = envelope.signal
    metadata = signal.metadata

    %{
      runtime_id: "rt-#{System.unique_integer([:positive])}",
      agent_id: signal.agent_id,
      agent_slug: signal.agent_slug,
      source: "system_event",
      responsibility_key: signal.responsibility_key,
      feature: signal.feature,
      trigger_kind: signal.trigger_kind,
      payload: envelope,
      reason: "runtime_offline"
    }
    |> Map.merge(DeadLetters.derive_subject(metadata))
    |> Map.merge(overrides)
  end

  # Wait for the supervisor to replace a deliberately-stopped singleton.
  defp wait_for_restart(old_pid, attempts \\ 100)

  defp wait_for_restart(old_pid, attempts) when attempts > 0 do
    case Process.whereis(Platform.Federation.DeadLetterReplay) do
      pid when pid == nil or pid == old_pid ->
        Process.sleep(20)
        wait_for_restart(old_pid, attempts - 1)

      other ->
        other
    end
  end

  defp wait_for_restart(_old_pid, _attempts), do: nil

  describe "record/1" do
    test "persists the full replay envelope, subject, and source" do
      stage_id = Ecto.UUID.generate()
      envelope = audit_diff_envelope(stage_id: stage_id)

      assert {:ok, %DeadLetter{} = row} = DeadLetters.record(base_attrs(envelope))

      # Reload from Postgres so we assert the WIRE form (jsonb), not the
      # in-memory struct we happened to build.
      reloaded = Repo.get!(DeadLetter, row.id)

      assert reloaded.disposition == "pending"
      assert reloaded.source == "system_event"
      assert reloaded.responsibility_key == "architecture.audit_diff"
      assert reloaded.trigger_kind == "event_topic"
      assert reloaded.subject_type == "stage"
      assert reloaded.subject_id == stage_id
      assert reloaded.attempts == 0
      assert reloaded.reason == "runtime_offline"
      refute is_nil(reloaded.occurred_at)
      assert is_nil(reloaded.dispositioned_at)

      # The load-bearing column: the envelope survives as string-keyed jsonb.
      assert reloaded.payload["signal"]["metadata"]["stage_id"] == stage_id
      assert reloaded.payload["signal"]["reason"] == "system_event"
      assert reloaded.payload["signal"]["trigger_kind"] == "event_topic"
      assert reloaded.payload["signal"]["responsibility_key"] == "architecture.audit_diff"
    end

    test "rejects a disposition outside the closed vocabulary" do
      envelope = audit_diff_envelope()

      assert {:error, changeset} =
               DeadLetters.record(base_attrs(envelope, %{disposition: "quarantined"}))

      assert "is invalid" in errors_on(changeset).disposition

      # Positive twin: every declared disposition IS representable, so the
      # rejection above is a vocabulary check and not a blanket refusal.
      for disposition <- DeadLetters.dispositions() do
        assert {:ok, %DeadLetter{}} =
                 DeadLetters.record(
                   base_attrs(envelope, %{
                     disposition: disposition,
                     runtime_id: "rt-vocab-#{System.unique_integer([:positive])}"
                   })
                 )
      end
    end

    test "a duplicate pending fire for the same subject collapses to one ledger row" do
      stage_id = Ecto.UUID.generate()
      envelope = audit_diff_envelope(stage_id: stage_id)
      attrs = base_attrs(envelope)

      assert {:ok, _} = DeadLetters.record(attrs)
      assert {:ok, _} = DeadLetters.record(attrs)

      assert Repo.aggregate(DeadLetter, :count) == 1
    end

    test "subject-less (cron) rows for the same runtime and key do NOT collide" do
      envelope = audit_diff_envelope()

      attrs =
        base_attrs(envelope, %{
          responsibility_key: "memory.dreaming",
          trigger_kind: :cron,
          subject_type: nil,
          subject_id: nil
        })

      assert {:ok, _} = DeadLetters.record(attrs)
      assert {:ok, _} = DeadLetters.record(attrs)

      assert Repo.aggregate(DeadLetter, :count) == 2
    end

    test "two different subjects for the same runtime and key both persist" do
      a = audit_diff_envelope()
      b = audit_diff_envelope()
      runtime_id = "rt-two-subjects"

      assert {:ok, _} = DeadLetters.record(base_attrs(a, %{runtime_id: runtime_id}))
      assert {:ok, _} = DeadLetters.record(base_attrs(b, %{runtime_id: runtime_id}))

      assert Repo.aggregate(DeadLetter, :count) == 2
    end
  end

  describe "derive_subject/1" do
    test "prefers stage, then plan, then task, and yields nil for a cron fire" do
      stage_id = Ecto.UUID.generate()
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      assert %{subject_type: "stage", subject_id: ^stage_id} =
               DeadLetters.derive_subject(%{
                 stage_id: stage_id,
                 plan_id: plan_id,
                 task_id: task_id
               })

      assert %{subject_type: "plan", subject_id: ^plan_id} =
               DeadLetters.derive_subject(%{plan_id: plan_id, task_id: task_id})

      assert %{subject_type: "task", subject_id: ^task_id} =
               DeadLetters.derive_subject(%{task_id: task_id})

      assert %{subject_type: nil, subject_id: nil} =
               DeadLetters.derive_subject(%{feature: "memory", trigger_kind: :cron})

      # String-keyed metadata (a jsonb round-trip) resolves identically.
      assert %{subject_type: "stage", subject_id: ^stage_id} =
               DeadLetters.derive_subject(%{"stage_id" => stage_id})
    end
  end

  describe "to_envelope/1" do
    test "round-trips a recorded envelope back to atom keys and atom values" do
      envelope = audit_diff_envelope()

      assert {:ok, row} = DeadLetters.record(base_attrs(envelope))
      reloaded = Repo.get!(DeadLetter, row.id)

      assert DeadLetters.to_envelope(reloaded) == envelope
    end

    test "restores atoms only from the whitelist and leaves unknown values as strings" do
      envelope = audit_diff_envelope()

      payload =
        put_in(envelope, [:signal, :trigger_kind], :cron)
        |> put_in([:signal, :metadata, :trigger_kind], :cron)

      assert {:ok, row} = DeadLetters.record(base_attrs(payload, %{trigger_kind: :cron}))
      rebuilt = DeadLetters.to_envelope(Repo.get!(DeadLetter, row.id))

      assert rebuilt.signal.trigger_kind == :cron
      assert rebuilt.signal.reason == :system_event

      # A value that is not in the whitelist is NOT atomized — this is the
      # guard against `String.to_atom/1` on data that crossed jsonb.
      hostile = Repo.get!(DeadLetter, row.id)

      hostile = %{
        hostile
        | payload: put_in(hostile.payload, ["signal", "trigger_kind"], "definitely_not_an_atom")
      }

      assert DeadLetters.to_envelope(hostile).signal.trigger_kind == "definitely_not_an_atom"
    end

    test "returns nil for a row with no stored payload" do
      envelope = audit_diff_envelope()

      assert {:ok, row} =
               DeadLetters.record(
                 base_attrs(envelope, %{
                   source: "chat",
                   payload: nil,
                   disposition: "dropped_policy",
                   reason: "chat_payload_not_replayable"
                 })
               )

      assert is_nil(DeadLetters.to_envelope(Repo.get!(DeadLetter, row.id)))
    end
  end

  describe "pending_for_runtime/2 and recent/1" do
    test "returns only pending rows for the runtime, oldest first" do
      runtime_id = "rt-pending-#{System.unique_integer([:positive])}"
      other_runtime = "rt-other-#{System.unique_integer([:positive])}"
      now = DateTime.utc_now()

      {:ok, older} =
        DeadLetters.record(
          base_attrs(audit_diff_envelope(), %{
            runtime_id: runtime_id,
            occurred_at: DateTime.add(now, -600, :second)
          })
        )

      {:ok, newer} =
        DeadLetters.record(
          base_attrs(audit_diff_envelope(), %{
            runtime_id: runtime_id,
            occurred_at: DateTime.add(now, -60, :second)
          })
        )

      {:ok, _terminal} =
        DeadLetters.record(
          base_attrs(audit_diff_envelope(), %{
            runtime_id: runtime_id,
            disposition: "replayed"
          })
        )

      {:ok, _elsewhere} =
        DeadLetters.record(base_attrs(audit_diff_envelope(), %{runtime_id: other_runtime}))

      pending = DeadLetters.pending_for_runtime(runtime_id)

      assert Enum.map(pending, & &1.id) == [older.id, newer.id]
      assert DeadLetters.pending_for_runtime(runtime_id, limit: 1) |> length() == 1

      # `recent/1` spans runtimes and dispositions.
      assert length(DeadLetters.recent(50)) == 4
    end
  end

  describe "mark/3" do
    test "sets the disposition, reason and dispositioned_at, and can bump attempts" do
      {:ok, row} = DeadLetters.record(base_attrs(audit_diff_envelope()))

      # `dispositioned_at` follows the SAME rule here as in `record/1`: it is
      # stamped for terminal dispositions and nil for live ones. `replaying` is
      # a claim, not a decision — stamping it would put a decision time on a
      # row whose decision has not been made, and stage 3's drain reverts
      # claims to `pending` often enough for that to matter. The claim's own
      # time is still recoverable from `updated_at`.
      assert {:ok, marked} = DeadLetters.mark(row, "replaying", bump_attempts: true)
      assert marked.disposition == "replaying"
      assert marked.attempts == 1
      assert is_nil(marked.dispositioned_at)

      assert {:ok, dropped} =
               DeadLetters.mark(marked, "dropped_stale", reason: "subject_superseded")

      assert dropped.disposition == "dropped_stale"
      assert dropped.reason == "subject_superseded"
      refute is_nil(dropped.dispositioned_at)
      # Not bumped this time — attempts counts delivery tries, not marks.
      assert dropped.attempts == 1
    end

    test "moving BACK to a live disposition clears dispositioned_at" do
      {:ok, row} = DeadLetters.record(base_attrs(audit_diff_envelope()))
      {:ok, settled} = DeadLetters.mark(row, "dropped_policy", reason: "stale_by_wall_clock")
      refute is_nil(settled.dispositioned_at)

      # The shape stage 3's drain produces when a runtime vanishes mid-delivery:
      # a claimed row goes back on the queue. A pending row still carrying a
      # dispositioned_at would assert a ruling that was explicitly un-made.
      assert {:ok, requeued} = DeadLetters.mark(settled, "pending", bump_attempts: true)
      assert requeued.disposition == "pending"
      assert is_nil(requeued.dispositioned_at)
      assert requeued.attempts == 1
      assert Repo.get!(DeadLetter, row.id).dispositioned_at == nil
    end

    test "refuses a disposition outside the closed vocabulary" do
      {:ok, row} = DeadLetters.record(base_attrs(audit_diff_envelope()))

      assert {:error, changeset} = DeadLetters.mark(row, "vanished")
      assert "is invalid" in errors_on(changeset).disposition

      # Positive twin — the row is untouched by the refusal.
      assert Repo.get!(DeadLetter, row.id).disposition == "pending"
    end
  end

  describe "prune/1" do
    test "deletes old terminal rows and NEVER deletes pending or replaying rows" do
      old = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)

      {:ok, old_pending} =
        DeadLetters.record(base_attrs(audit_diff_envelope(), %{occurred_at: old}))

      {:ok, old_replaying} =
        DeadLetters.record(
          base_attrs(audit_diff_envelope(), %{occurred_at: old, disposition: "replaying"})
        )

      {:ok, old_replayed} =
        DeadLetters.record(
          base_attrs(audit_diff_envelope(), %{occurred_at: old, disposition: "replayed"})
        )

      {:ok, fresh_replayed} =
        DeadLetters.record(base_attrs(audit_diff_envelope(), %{disposition: "replayed"}))

      assert {:ok, 1} = DeadLetters.prune(days: 30)

      # The one terminal-and-old row is gone …
      refute Repo.get(DeadLetter, old_replayed.id)
      # … and every row the queue still needs survives.
      assert Repo.get(DeadLetter, old_pending.id)
      assert Repo.get(DeadLetter, old_replaying.id)
      assert Repo.get(DeadLetter, fresh_replayed.id)
    end
  end

  # ── Stage 4: cumulative counters ─────────────────────────────────────
  #
  # `Reachability.report/0` read 19 `:broadcastable` and 0 `:runtime_offline`
  # at 20:55Z on 2026-07-27 — a day that had already lost 39 fires to
  # `:runtime_offline`. It was a SNAPSHOT of a time-varying class. These tests
  # exist to pin the two properties that make a counter a different kind of
  # number from a query over the ledger.

  describe "counters vs. the ledger" do
    test "a deduped pending fire leaves ONE ledger row but counts TWO losses" do
      # THE anti-vacuity assertion for this stage. `SELECT count(*)` over the
      # ledger would report 1 here, because stage 1's partial unique index
      # collapses the second pending fire on purpose. Two fires were still
      # lost, and a loss measure that reports 1 is the ticket's own defect one
      # layer down.
      runtime_id = "rt-dedupe-#{System.unique_integer([:positive])}"
      stage_id = Ecto.UUID.generate()
      attrs = base_attrs(audit_diff_envelope(stage_id: stage_id), %{runtime_id: runtime_id})

      assert {:ok, _} = DeadLetters.record(attrs)
      assert {:ok, _} = DeadLetters.record(attrs)

      assert Repo.aggregate(DeadLetter, :count) == 1

      totals = DeadLetters.counter_totals()
      assert totals["recorded"] == 2
      # The collapsed second fire is not silently dropped from the accounting
      # — it lands on the vocabulary word that describes exactly what happened
      # to it, which is what keeps the invariant balanced.
      assert totals["superseded_duplicate"] == 1

      assert DeadLetters.loss_summary().balanced
    end

    test "two DISTINCT subjects record two ledger rows and no supersession" do
      # The fresh twin of the test above. Without it, a `record/1` that
      # unconditionally counted `superseded_duplicate` would still be green.
      runtime_id = "rt-distinct-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               DeadLetters.record(base_attrs(audit_diff_envelope(), %{runtime_id: runtime_id}))

      assert {:ok, _} =
               DeadLetters.record(base_attrs(audit_diff_envelope(), %{runtime_id: runtime_id}))

      assert Repo.aggregate(DeadLetter, :count) == 2

      totals = DeadLetters.counter_totals()
      assert totals["recorded"] == 2
      assert totals["superseded_duplicate"] == 0
      assert DeadLetters.loss_summary().balanced
    end

    test "counters survive the ledger row being pruned away" do
      old = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)

      {:ok, row} =
        DeadLetters.record(base_attrs(audit_diff_envelope(), %{occurred_at: old}))

      assert {:ok, _} = DeadLetters.mark(row, "replayed", bump_attempts: true)
      assert {:ok, 1} = DeadLetters.prune(days: 30)

      # The ledger has forgotten it — this is the queue doing its job.
      assert Repo.aggregate(DeadLetter, :count) == 0

      # The measure has not. A count over the ledger would now read 0
      # recorded and 0 replayed, which is a number that shrank without
      # anything being un-lost.
      totals = DeadLetters.counter_totals()
      assert totals["recorded"] == 1
      assert totals["replayed"] == 1

      summary = DeadLetters.loss_summary()
      assert summary.recorded == 1
      assert summary.replayed == 1
      assert summary.pending == 0
      assert summary.balanced
    end

    test "NULL responsibility_key/trigger_kind collapse onto ONE counter row" do
      # NULLS NOT DISTINCT on the counter table's unique index. Under
      # Postgres' default NULLS DISTINCT every cron-shaped record (no key, no
      # kind) would insert a FRESH counter row instead of incrementing one, so
      # the table would grow one row per loss — an append-only log wearing a
      # counter's name, and unbounded exactly where the moduledoc promises
      # bounded cardinality.
      runtime_id = "rt-nulls-#{System.unique_integer([:positive])}"

      attrs =
        base_attrs(audit_diff_envelope(), %{
          runtime_id: runtime_id,
          responsibility_key: nil,
          trigger_kind: nil,
          subject_type: nil,
          subject_id: nil
        })

      assert {:ok, _} = DeadLetters.record(attrs)
      assert {:ok, _} = DeadLetters.record(attrs)
      assert {:ok, _} = DeadLetters.record(attrs)

      # Three separate ledger rows: the pending index excludes NULL subjects,
      # so nothing deduped here and all three are genuinely distinct losses.
      assert Repo.aggregate(DeadLetter, :count) == 3

      recorded_rows =
        DeadLetters.stats()
        |> Enum.filter(&(&1.runtime_id == runtime_id and &1.disposition == "recorded"))

      assert [%{count: 3, responsibility_key: nil, trigger_kind: nil}] = recorded_rows
      assert DeadLetters.counter_totals()["recorded"] == 3
    end
  end

  describe "loss_summary/0 and the accounting invariant" do
    test "recorded == terminals + outstanding after a mixed set of fates" do
      runtime_id = "rt-invariant-#{System.unique_integer([:positive])}"
      stage_id = Ecto.UUID.generate()

      # 1 — replayed.
      {:ok, replayed} =
        DeadLetters.record(base_attrs(audit_diff_envelope(), %{runtime_id: runtime_id}))

      {:ok, claimed} = DeadLetters.mark(replayed, "replaying")
      {:ok, _} = DeadLetters.mark(claimed, "replayed")

      # 2 — dropped by policy.
      {:ok, cron} =
        DeadLetters.record(
          base_attrs(audit_diff_envelope(), %{
            runtime_id: runtime_id,
            responsibility_key: "memory.dreaming",
            trigger_kind: :cron,
            subject_type: nil,
            subject_id: nil
          })
        )

      {:ok, _} = DeadLetters.mark(cron, "dropped_policy", reason: "stale_by_wall_clock")

      # 3 — dropped stale.
      {:ok, stale} =
        DeadLetters.record(base_attrs(audit_diff_envelope(), %{runtime_id: runtime_id}))

      {:ok, _} = DeadLetters.mark(stale, "dropped_stale", reason: "subject_superseded")

      # 4 — abandoned.
      {:ok, doomed} =
        DeadLetters.record(base_attrs(audit_diff_envelope(), %{runtime_id: runtime_id}))

      {:ok, _} = DeadLetters.mark(doomed, "abandoned", reason: "max_attempts_exceeded")

      # 5 — chat row, terminal at write time.
      {:ok, _chat} =
        DeadLetters.record(
          base_attrs(audit_diff_envelope(), %{
            runtime_id: runtime_id,
            source: "chat",
            payload: nil,
            disposition: "dropped_policy",
            reason: "chat_payload_not_replayable",
            subject_type: nil,
            subject_id: nil
          })
        )

      # 6 — a deduped pending fire (counted twice, one ledger row).
      dupe = base_attrs(audit_diff_envelope(stage_id: stage_id), %{runtime_id: runtime_id})
      {:ok, _} = DeadLetters.record(dupe)
      {:ok, _} = DeadLetters.record(dupe)

      # 7 — still pending, untouched.
      {:ok, _} =
        DeadLetters.record(base_attrs(audit_diff_envelope(), %{runtime_id: runtime_id}))

      summary = DeadLetters.loss_summary()

      # 4 singletons + 1 chat + 2 dedupe attempts + 1 pending = 8 losses.
      assert summary.recorded == 8
      assert summary.replayed == 1
      assert summary.dropped_policy == 2
      assert summary.dropped_stale == 1
      assert summary.abandoned == 1
      assert summary.superseded_duplicate == 1
      # Two rows are still in the ledger and live: the deduped one and #7.
      assert summary.pending == 2

      assert summary.recorded ==
               summary.replayed + summary.dropped_policy + summary.dropped_stale +
                 summary.superseded_duplicate + summary.abandoned + summary.pending

      assert summary.balanced
      assert summary.dropped == 3
      assert summary.replay_rate == 0.125
    end

    test "a claim reverted to pending writes no counter and keeps the books balanced" do
      # Stage 3's drain marks `replaying` then reverts to `pending` when a
      # runtime vanishes mid-delivery. Counting live dispositions would make
      # every flap inflate the totals and no invariant could survive it — a
      # live disposition is a STATE, and the ledger (which never prunes
      # pending rows) is the right place to read a state from.
      {:ok, row} = DeadLetters.record(base_attrs(audit_diff_envelope()))

      {:ok, claimed} = DeadLetters.mark(row, "replaying")
      {:ok, _} = DeadLetters.mark(claimed, "pending", bump_attempts: true)

      totals = DeadLetters.counter_totals()
      assert totals["recorded"] == 1
      refute Map.has_key?(totals, "replaying")
      refute Map.has_key?(totals, "pending")

      summary = DeadLetters.loss_summary()
      assert summary.pending == 1
      assert summary.balanced
    end

    test "re-marking an already-terminal row does not double-count it" do
      {:ok, row} = DeadLetters.record(base_attrs(audit_diff_envelope()))
      {:ok, replayed} = DeadLetters.mark(row, "replayed")
      {:ok, _} = DeadLetters.mark(replayed, "replayed")

      assert DeadLetters.counter_totals()["replayed"] == 1
      assert DeadLetters.loss_summary().balanced
    end

    test "replay_rate is 0.0 with nothing recorded and the books still balance" do
      summary = DeadLetters.loss_summary()

      assert summary.recorded == 0
      assert summary.replay_rate == 0.0
      assert summary.balanced
    end
  end

  describe "stats/0, stats_for_key/1 and rollup_line/0" do
    test "stats rows carry first_at/last_at and key on runtime + key + kind + disposition" do
      runtime_id = "rt-stats-#{System.unique_integer([:positive])}"

      {:ok, first} =
        DeadLetters.record(base_attrs(audit_diff_envelope(), %{runtime_id: runtime_id}))

      {:ok, _second} =
        DeadLetters.record(base_attrs(audit_diff_envelope(), %{runtime_id: runtime_id}))

      [row] =
        DeadLetters.stats()
        |> Enum.filter(&(&1.runtime_id == runtime_id and &1.disposition == "recorded"))

      assert row.count == 2
      assert row.responsibility_key == "architecture.audit_diff"
      assert row.trigger_kind == "event_topic"
      assert DateTime.compare(row.first_at, row.last_at) in [:lt, :eq]

      # A different disposition for the same key is a DIFFERENT counter row,
      # which is what lets stage 5 render the per-key breakdown.
      {:ok, _} = DeadLetters.mark(first, "replayed")

      dispositions =
        DeadLetters.stats()
        |> Enum.filter(&(&1.runtime_id == runtime_id))
        |> Enum.map(& &1.disposition)
        |> Enum.sort()

      assert dispositions == ["recorded", "replayed"]
    end

    test "stats_for_key/1 filters to one responsibility key" do
      runtime_id = "rt-forkey-#{System.unique_integer([:positive])}"

      {:ok, _} =
        DeadLetters.record(base_attrs(audit_diff_envelope(), %{runtime_id: runtime_id}))

      {:ok, _} =
        DeadLetters.record(
          base_attrs(audit_diff_envelope(), %{
            runtime_id: runtime_id,
            responsibility_key: "architecture.review_plan"
          })
        )

      keys =
        "architecture.audit_diff"
        |> DeadLetters.stats_for_key()
        |> Enum.map(& &1.responsibility_key)
        |> Enum.uniq()

      assert keys == ["architecture.audit_diff"]
      assert DeadLetters.stats_for_key("architecture.review_plan") |> length() == 1
      assert DeadLetters.stats_for_key("nothing.here") == []
    end

    test "rollup_line/0 reports cumulative totals and the top key" do
      {:ok, replayed} = DeadLetters.record(base_attrs(audit_diff_envelope()))
      {:ok, _} = DeadLetters.mark(replayed, "replayed")
      {:ok, _} = DeadLetters.record(base_attrs(audit_diff_envelope()))

      {:ok, _} =
        DeadLetters.record(
          base_attrs(audit_diff_envelope(), %{responsibility_key: "architecture.review_plan"})
        )

      line = DeadLetters.rollup_line()

      assert line =~ "[DeadLetters] cumulative"
      assert line =~ "recorded=3"
      assert line =~ "replayed=1"
      assert line =~ "dropped_policy=0"
      assert line =~ "dropped_stale=0"
      assert line =~ "superseded_duplicate=0"
      assert line =~ "abandoned=0"
      assert line =~ "pending=2"
      assert line =~ "top_key=architecture.audit_diff"
    end

    test "rollup_line/0 says so plainly when nothing has ever been lost" do
      line = DeadLetters.rollup_line()

      assert line =~ "recorded=0"
      assert line =~ "top_key=none"
    end
  end

  describe "counter durability" do
    test "loss_summary/0 is unchanged across a DeadLetterReplay restart" do
      {:ok, replayed} = DeadLetters.record(base_attrs(audit_diff_envelope()))
      {:ok, _} = DeadLetters.mark(replayed, "replayed")
      {:ok, _} = DeadLetters.record(base_attrs(audit_diff_envelope()))

      before = DeadLetters.loss_summary()
      assert before.recorded == 2

      pid = Process.whereis(Platform.Federation.DeadLetterReplay)
      assert is_pid(pid)

      ref = Process.monitor(pid)
      GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

      restarted = wait_for_restart(pid)
      assert is_pid(restarted)
      assert restarted != pid

      # The whole reason stage 1 chose Ecto over the org's ETS default: the
      # old 50-entry in-process `DeadLetterBuffer` returned an EMPTY list
      # here. (An ExUnit test cannot restart the BEAM; the task-level
      # e2e_behavior script covers the full-shutdown case.)
      assert DeadLetters.loss_summary() == before
    end
  end

  describe "telemetry" do
    test "emits :recorded on every record attempt and :dispositioned on a terminal mark" do
      handler_id = "dead-letter-counters-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [
          [:platform, :federation, :dead_letter, :recorded],
          [:platform, :federation, :dead_letter, :dispositioned]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      runtime_id = "rt-telemetry-#{System.unique_integer([:positive])}"
      attrs = base_attrs(audit_diff_envelope(), %{runtime_id: runtime_id})

      {:ok, row} = DeadLetters.record(attrs)

      assert_receive {:telemetry, [:platform, :federation, :dead_letter, :recorded], %{count: 1},
                      recorded_meta}

      assert recorded_meta.runtime_id == runtime_id
      assert recorded_meta.responsibility_key == "architecture.audit_diff"
      assert recorded_meta.trigger_kind == "event_topic"
      assert recorded_meta.disposition == "pending"
      refute recorded_meta.deduped

      # A deduped fire still emits — an event that fired only when a ledger
      # row appeared would be blind to exactly the losses this stage exists
      # to count.
      {:ok, _} = DeadLetters.record(attrs)

      assert_receive {:telemetry, [:platform, :federation, :dead_letter, :recorded], %{count: 1},
                      deduped_meta}

      assert deduped_meta.deduped

      {:ok, _} = DeadLetters.mark(row, "dropped_stale", reason: "subject_superseded")

      assert_receive {:telemetry, [:platform, :federation, :dead_letter, :dispositioned],
                      %{count: 1}, disposed_meta}

      assert disposed_meta.disposition == "dropped_stale"
      assert disposed_meta.responsibility_key == "architecture.audit_diff"
      assert disposed_meta.runtime_id == runtime_id
    end
  end
end
