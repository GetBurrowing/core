defmodule Platform.Memory.MaintenanceSubagentTest do
  @moduledoc """
  Behaviour tests for `Platform.Memory.MaintenanceSubagent` — the
  fan-out adapter that dispatches ONE fresh subagent per
  `Platform.Memory.Integrity.scan/1` entry.

  The regression guards here are load-bearing:

    * Each `spawn_*` fn spins one task per input item.
    * A single failing op does NOT cancel the surrounding batch —
      surviving items still complete + still record audit rows.
    * The per-item runner sees EXACTLY ONE item (scoped payload) — never
      the full items list, never batch-level context. Acceptance
      criterion 10 in ADR-0041 M8 hinges on this: a regression here
      would silently balloon the LLM subagent context once the runner
      grows an LLM invocation in the follow-up stage.
  """
  use Platform.DataCase, async: false

  alias Platform.Audit
  alias Platform.Memory.MaintenanceSubagent
  alias Platform.Org.Wiki

  # A collector runner that records the exact (op, item, opts) triple it
  # was invoked with. Simulates a variable outcome per item so we can
  # test both success + failure interleaving in one batch. The recorded
  # payload is stored on the caller's process dictionary so the assertion
  # side can pattern-match without carrying agent-refs around.
  defp recording_runner(collector_pid, per_item_outcome) do
    fn op, item, opts ->
      send(collector_pid, {:runner_call, op, item, opts})
      per_item_outcome.(op, item, opts)
    end
  end

  defp drain_runner_calls do
    drain_runner_calls([])
  end

  defp drain_runner_calls(acc) do
    receive do
      {:runner_call, op, item, opts} ->
        drain_runner_calls([{op, item, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp fake_item(overrides \\ %{}) do
    Map.merge(
      %{
        source_id: Ecto.UUID.generate(),
        source_path: "org/page/notes.md",
        target_path: "identity",
        resolved_target_path: "org/page/identity.md"
      },
      overrides
    )
  end

  # ── Fan-out: one subagent per item ───────────────────────────────────

  describe "spawn_link_repair/2 — fan-out shape" do
    test "invokes runner exactly once per item, records one audit row per ok result" do
      collector = self()

      items =
        for i <- 1..3 do
          fake_item(%{
            source_id: Ecto.UUID.generate(),
            source_path: "org/page/note-#{i}.md",
            target_path: "target-#{i}",
            resolved_target_path: nil
          })
        end

      runner =
        recording_runner(collector, fn _op, _item, _opts ->
          {:ok, %{before_hash: "b", after_hash: "a", notes: "ok"}}
        end)

      results = MaintenanceSubagent.spawn_link_repair(items, runner: runner)

      assert length(results) == 3
      assert Enum.all?(results, &match?({:ok, %Audit.Event{}}, &1))

      # Exactly one runner invocation per item.
      calls = drain_runner_calls()
      assert length(calls) == 3

      # Each call carried a single item — never the full list.
      Enum.each(calls, fn {op, item, _opts} ->
        assert op == :link_repair
        assert is_map(item)
        # Regression guard for acceptance criterion 10: the payload the
        # runner sees is the ONE entry, not the batch.
        refute is_list(item)
        assert Map.has_key?(item, :source_id)
        assert Map.has_key?(item, :source_path)
        assert Map.has_key?(item, :target_path)
      end)

      # Audit rows have the right event_type + actor_slug metadata.
      events =
        Audit.list(event_type: "platform.memory.maintenance.link_repair", limit: 10)

      assert length(events) == 3

      Enum.each(events, fn event ->
        assert event.event_type == "platform.memory.maintenance.link_repair"
        assert event.actor_type == "agent"
        assert event.action == "link_repair"
        assert event.metadata["actor_slug"] == "historian.dreaming"
        assert event.metadata["outcome"] == "ok"
      end)
    end
  end

  # ── Per-item runner isolation (LOAD-BEARING) ─────────────────────────

  describe "runner payload scoping — acceptance criterion 10 regression guard" do
    test "runner opts contain only whitelisted keys, never the full items list" do
      collector = self()

      items = [
        fake_item(%{source_path: "org/page/a.md"}),
        fake_item(%{source_path: "org/page/b.md"})
      ]

      runner =
        recording_runner(collector, fn _op, _item, _opts ->
          {:ok, %{before_hash: "x", after_hash: "y", notes: nil}}
        end)

      _results =
        MaintenanceSubagent.spawn_format_normalize(items,
          runner: runner,
          actor_slug: "historian.dreaming",
          actor_id: nil,
          workspace_id: nil,
          # Extra opts callers might pass that MUST NOT leak into the
          # per-item runner scope.
          items: items,
          batch_id: "should-not-leak",
          extra: %{foo: :bar}
        )

      calls = drain_runner_calls()
      assert length(calls) == 2

      Enum.each(calls, fn {_op, _item, opts} ->
        opts_keys = MapSet.new(Keyword.keys(opts))

        # Whitelist: only these opts may reach the runner.
        allowed = MapSet.new([:workspace_id, :actor_slug, :actor_id])
        leaked = MapSet.difference(opts_keys, allowed)

        assert MapSet.size(leaked) == 0,
               "opts leaked into runner scope: #{inspect(MapSet.to_list(leaked))}"

        # Explicit negative assertions on the most-dangerous keys.
        refute Keyword.has_key?(opts, :items)
        refute Keyword.has_key?(opts, :batch_id)
        refute Keyword.has_key?(opts, :extra)
        refute Keyword.has_key?(opts, :runner)
      end)
    end
  end

  # ── Failure isolation ────────────────────────────────────────────────

  describe "failure isolation — one bad op does not cancel the batch" do
    test "surviving items still complete + still record audit rows" do
      collector = self()

      items = [
        fake_item(%{source_id: Ecto.UUID.generate(), source_path: "org/page/ok-1.md"}),
        fake_item(%{source_id: Ecto.UUID.generate(), source_path: "org/page/boom.md"}),
        fake_item(%{source_id: Ecto.UUID.generate(), source_path: "org/page/ok-3.md"})
      ]

      runner =
        recording_runner(collector, fn _op, item, _opts ->
          if item.source_path == "org/page/boom.md" do
            {:error, :simulated_failure}
          else
            {:ok, %{before_hash: "b", after_hash: "a", notes: "ok"}}
          end
        end)

      results = MaintenanceSubagent.spawn_retired_cleanup(items, runner: runner)

      assert length(results) == 3

      assert [
               {:ok, %Audit.Event{}},
               {:error, :simulated_failure, boom_item},
               {:ok, %Audit.Event{}}
             ] = results

      assert boom_item.source_path == "org/page/boom.md"

      # Even the failure path records an audit row (outcome: "error")
      # so a post-hoc auditor can see the subagent tried and failed.
      events =
        Audit.list(event_type: "platform.memory.maintenance.retired_cleanup", limit: 10)

      assert length(events) == 3

      outcomes =
        events
        |> Enum.map(& &1.metadata["outcome"])
        |> Enum.sort()

      assert outcomes == ["error", "ok", "ok"]

      # The error row also carries the reason for spot-check triage.
      error_row = Enum.find(events, &(&1.metadata["outcome"] == "error"))
      assert error_row.metadata["reason"] =~ "simulated_failure"
    end

    test "runner that raises is caught + returned as {:error, {:runner_raised, msg}}" do
      original = fake_item()
      items = [original]

      runner = fn _op, _item, _opts ->
        raise "boom"
      end

      [result] = MaintenanceSubagent.spawn_link_repair(items, runner: runner)

      assert {:error, {:runner_raised, "boom"}, returned_item} = result
      assert returned_item == original
    end
  end

  # ── Empty bucket short-circuit ───────────────────────────────────────

  describe "empty items" do
    test "spawn_link_repair/2 returns [] without invoking the runner" do
      collector = self()

      runner =
        recording_runner(collector, fn _op, _item, _opts ->
          {:ok, %{before_hash: "b", after_hash: "a", notes: nil}}
        end)

      assert [] = MaintenanceSubagent.spawn_link_repair([], runner: runner)
      assert [] = MaintenanceSubagent.spawn_format_normalize([], runner: runner)
      assert [] = MaintenanceSubagent.spawn_retired_cleanup([], runner: runner)

      # No runner call happened.
      assert drain_runner_calls() == []
    end
  end

  # ── Default runner: content rewrite + hashes ─────────────────────────

  describe "default runner (no :runner opt) — content rewrite via Wiki.upsert_page" do
    setup do
      # Seed a page containing the wikilink shape the runner will
      # rewrite. Both a plain reference and an alias-style reference so
      # the regex covers both.
      {:ok, _target} = Wiki.upsert_page("org/page/identity.md", %{content: "canonical target"})

      {:ok, source} =
        Wiki.upsert_page("org/page/notes.md", %{
          content: "See [[identity]] and [[identity|the id page]] for detail."
        })

      %{source: source}
    end

    test "format_normalize rewrites bare basename to absolute file_key", %{source: source} do
      item = %{
        source_id: source.id,
        source_path: source.file_key,
        target_path: "identity",
        resolved_target_path: "org/page/identity.md"
      }

      [{:ok, %Audit.Event{} = event}] = MaintenanceSubagent.spawn_format_normalize([item])

      assert event.metadata["outcome"] == "ok"
      assert event.metadata["before_hash"] != event.metadata["after_hash"]
      assert event.metadata["notes"] =~ "replaced"

      updated = Wiki.get_page("org/page/notes.md")
      assert updated.content =~ "[[org/page/identity.md]]"
      assert updated.content =~ "[[org/page/identity.md|the id page]]"
      refute updated.content =~ "[[identity]]"
    end

    test "link_repair without resolved_target strips the wikilink brackets", %{source: source} do
      # Simulate a broken bucket entry — no resolved target.
      item = %{
        source_id: source.id,
        source_path: source.file_key,
        target_path: "identity",
        resolved_target_path: nil
      }

      [{:ok, %Audit.Event{} = event}] = MaintenanceSubagent.spawn_link_repair([item])

      assert event.metadata["outcome"] == "ok"
      assert event.metadata["notes"] =~ "stripped"

      updated = Wiki.get_page("org/page/notes.md")
      # Bracket-form gone.
      refute updated.content =~ "[[identity]]"
      # Text preserved.
      assert updated.content =~ "identity"
      # Alias form's display text preserved.
      assert updated.content =~ "the id page"
    end

    test "no-op rewrite (target string absent from page) records notes=\"no-op\"", %{source: _s} do
      # Item pointing at a target that isn't in the page body.
      {:ok, clean_source} =
        Wiki.upsert_page("org/page/clean.md", %{content: "no wikilinks here"})

      item = %{
        source_id: clean_source.id,
        source_path: "org/page/clean.md",
        target_path: "identity",
        resolved_target_path: "org/page/identity.md"
      }

      [{:ok, %Audit.Event{} = event}] = MaintenanceSubagent.spawn_format_normalize([item])

      assert event.metadata["outcome"] == "ok"
      assert event.metadata["notes"] == "no-op"
      assert event.metadata["before_hash"] == event.metadata["after_hash"]

      # Page content unchanged.
      unchanged = Wiki.get_page("org/page/clean.md")
      assert unchanged.content == "no wikilinks here"
    end

    test "missing source page fails cleanly, still records error audit row" do
      item = %{
        source_id: Ecto.UUID.generate(),
        source_path: "org/page/ghost.md",
        target_path: "identity",
        resolved_target_path: "org/page/identity.md"
      }

      [{:error, {:source_page_missing, "org/page/ghost.md"}, ^item}] =
        MaintenanceSubagent.spawn_format_normalize([item])

      [event] =
        Audit.list(event_type: "platform.memory.maintenance.format_normalize", limit: 10)

      assert event.metadata["outcome"] == "error"
      assert event.metadata["reason"] =~ "source_page_missing"
    end
  end
end
