defmodule Platform.Memory.DreamingMaintenanceE2ETest do
  @moduledoc """
  Cases B and E of task 019f70e9's stage-8 e2e evaluation, kept when task
  01a13867 stage 5 retired the Proposals review flow and deleted
  `dreaming_review_e2e_test.exs`. Cases A, C and D exercised
  `Platform.Memory.Proposals` (approve/promote, reject feedback, TTL
  expiry), which no longer exists; their successors are the Insights tests
  (`test/platform/memory/insights_test.exs`, `insights/actions_test.exs`,
  `insights/purger_test.exs`). B and E exercise the dreaming handler's
  maintenance side, which is unchanged, so they stay.

  Case B's "no proposal blocks" assertion now counts the legacy
  `memory_proposals` table AND `memory_insights`: auto-applied maintenance
  must create neither.
  """
  use Platform.DataCase, async: false

  alias Platform.Audit
  alias Platform.Memory.MaintenanceSubagent
  alias Platform.Org.Context, as: OrgContext
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Responsibilities.Handlers.Dreaming
  alias Platform.Responsibilities.Responsibility

  setup do
    Repo.delete_all(WikiPage)
    Repo.delete_all(Platform.MemoryFeedback.Entry)
    Repo.delete_all(Platform.Audit.Event)
    :ok
  end

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: Dreaming.key(),
      feature: "memory",
      trigger_kind: "cron",
      trigger_config: %{"expression" => "0 3 * * *", "timezone" => "America/Chicago"},
      scope: "per_org",
      context_provided: ["recent_journal", "org_identity"],
      enabled: true
    }
  end

  defp todays_journal, do: Dreaming.journal_file_key(Date.utc_today())

  describe "Case B: format_normalize auto-apply, 3 bare-slug references" do
    test "3 bare refs auto-normalize, 3 audit rows, NO proposal blocks, journal summary count=3" do
      # ── Setup: 3 target pages + 3 referrers with bare wikilinks ─────────
      {:ok, _acme} = Wiki.upsert_page("org/page/team/acme.md", %{content: "Acme anchor page."})

      {:ok, _higgins} =
        Wiki.upsert_page("org/page/team/higgins.md", %{content: "Higgins anchor page."})

      {:ok, _saru} = Wiki.upsert_page("org/page/team/saru.md", %{content: "Saru anchor page."})

      {:ok, _ref_a} =
        Wiki.upsert_page("org/page/ref-a.md", %{
          content: "See [[acme]] for background."
        })

      {:ok, _ref_b} =
        Wiki.upsert_page("org/page/ref-b.md", %{
          content: "See [[higgins]] for background."
        })

      {:ok, _ref_c} =
        Wiki.upsert_page("org/page/ref-c.md", %{
          content: "See [[saru]] for background."
        })

      # Sanity: Integrity.scan returns exactly 3 :format_dirty rows.
      scan_report = Platform.Memory.Integrity.scan([])

      assert length(scan_report.format_dirty) == 3,
             "expected 3 format_dirty rows, got #{length(scan_report.format_dirty)}"

      assert scan_report.broken == []
      assert scan_report.retired_target == []

      proposals_before =
        Repo.aggregate("memory_proposals", :count) +
          Repo.aggregate(Platform.Memory.Insight, :count)

      # ── Fire the handler with an empty synthesis body (no proposal blocks,
      #    only the maintenance side is what we're validating). ────────────
      assert :ok =
               Dreaming.handle_output(
                 responsibility(),
                 %{"memory_body" => "# Empty dream — maintenance only\n"},
                 %{kind: :cron}
               )

      # ── Expected 1: all 3 pages now have absolute-form links. ────────
      page_a = Wiki.get_page("org/page/ref-a.md")
      page_b = Wiki.get_page("org/page/ref-b.md")
      page_c = Wiki.get_page("org/page/ref-c.md")

      assert page_a.content =~ "[[org/page/team/acme.md]]",
             "ref-a not rewritten to absolute form: #{page_a.content}"

      refute page_a.content =~ "[[acme]]", "ref-a still contains bare-slug reference"

      assert page_b.content =~ "[[org/page/team/higgins.md]]",
             "ref-b not rewritten to absolute form: #{page_b.content}"

      refute page_b.content =~ "[[higgins]]", "ref-b still contains bare-slug reference"

      assert page_c.content =~ "[[org/page/team/saru.md]]",
             "ref-c not rewritten to absolute form: #{page_c.content}"

      refute page_c.content =~ "[[saru]]", "ref-c still contains bare-slug reference"

      # ── Expected 2: exactly 3 audit rows with format_normalize kind. ──
      events =
        Audit.list(event_type: "platform.memory.maintenance.format_normalize", limit: 100)

      assert length(events) == 3,
             "expected 3 format_normalize audit rows, got #{length(events)}"

      source_paths = Enum.map(events, & &1.metadata["source_path"]) |> Enum.sort()

      assert source_paths == [
               "org/page/ref-a.md",
               "org/page/ref-b.md",
               "org/page/ref-c.md"
             ]

      # ── Expected 3: NO proposal blocks materialized (auto-apply, not
      #    proposal, per acceptance criterion 4). ──────────────────────
      proposals_after =
        Repo.aggregate("memory_proposals", :count) +
          Repo.aggregate(Platform.Memory.Insight, :count)

      assert proposals_after == proposals_before,
             "expected 0 new proposals or insights from auto-applied maintenance; got #{proposals_after - proposals_before}"

      # ── Expected 4: journal auto-applied summary mentions count=3. ────
      journal = OrgContext.get_file(todays_journal())
      assert journal.content =~ "format_normalize: 3 succeeded, 0 failed"
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Case C — reject-with-feedback → few-shot corpus

  # ─────────────────────────────────────────────────────────────────────
  # Case E — 10 link_repair subagent spawns with per-item payload scoping (LOAD-BEARING)
  # ─────────────────────────────────────────────────────────────────────
  describe "Case E: 10 link_repair spawns, per-item scoping, no parent-transcript diff leakage" do
    test "acceptance criterion 10 regression guard scaled to 10 items" do
      collector = self()

      items =
        for i <- 1..10 do
          %{
            source_id: Ecto.UUID.generate(),
            source_path: "org/page/broken-#{i}.md",
            target_path: "dangling-#{i}",
            resolved_target_path: nil
          }
        end

      # Test-double runner: records the exact (op, item, opts) triple it
      # was invoked with. Simulates a successful link_repair per item.
      runner = fn op, item, opts ->
        send(collector, {:runner_call, op, item, opts})

        {:ok,
         %{
           before_hash: "b#{item.target_path}",
           after_hash: "a#{item.target_path}",
           notes: "test-double repair"
         }}
      end

      results =
        MaintenanceSubagent.spawn_link_repair(items,
          runner: runner,
          actor_slug: "historian.dreaming",
          # Extra opts callers might pass — MUST NOT leak into per-item
          # scope (regression guard for the per-item payload scoping).
          items: items,
          batch_id: "e2e-case-e",
          full_scan_report: %{broken: items, format_dirty: [], retired_target: []}
        )

      # ── Expected 1: exactly 10 subagent spawns occurred. ───────────────
      calls =
        Enum.reduce(1..10, [], fn _, acc ->
          receive do
            {:runner_call, op, item, opts} -> [{op, item, opts} | acc]
          after
            500 -> acc
          end
        end)
        |> Enum.reverse()

      assert length(calls) == 10, "expected 10 runner invocations, got #{length(calls)}"

      # ── Expected 2: each subagent's payload contains EXACTLY ONE item. ─
      Enum.each(calls, fn {op, item, opts} ->
        assert op == :link_repair
        assert is_map(item)
        refute is_list(item), "payload was a list, not a single item — batch leaked into subagent"

        assert Map.has_key?(item, :source_id)
        assert Map.has_key?(item, :source_path)
        assert Map.has_key?(item, :target_path)

        # The runner opts must contain ONLY the whitelisted keys.
        opts_keys = MapSet.new(Keyword.keys(opts))
        allowed = MapSet.new([:workspace_id, :actor_slug, :actor_id])
        leaked = MapSet.difference(opts_keys, allowed)

        assert MapSet.size(leaked) == 0,
               "opts leaked into runner scope: #{inspect(MapSet.to_list(leaked))}"

        # Explicit negative assertions on the most dangerous keys.
        refute Keyword.has_key?(opts, :items)
        refute Keyword.has_key?(opts, :batch_id)
        refute Keyword.has_key?(opts, :full_scan_report)
        refute Keyword.has_key?(opts, :runner)
      end)

      # ── Expected 3: parent-orchestrator transcript contains no [[...]]
      #    diff strings for individual repairs. ────────────────────────
      # The "parent transcript" is the return value of spawn_link_repair
      # (what the Historian orchestrator receives back). It is a list of
      # {:ok, %Audit.Event{}} tuples — the individual diff strings live
      # in each subagent's audit-row metadata, NOT in the parent's return.
      assert length(results) == 10

      Enum.each(results, fn
        {:ok, %Audit.Event{}} -> :ok
        other -> flunk("unexpected result shape: #{inspect(other)}")
      end)

      parent_transcript = inspect(results)

      refute parent_transcript =~ "[[",
             "parent transcript contains wikilink diff strings — leaked from subagent scope"

      # Also verify the Handlers.Dreaming summarize function reduces to a
      # count-only shape (Historian's parent context sees %{ok: 10, error: 0},
      # not the item list).
      # This is what the run_maintenance/1 return holds — no per-link text.
      # We can't call the private summarize/1, but we can verify the
      # journal body composition (which is what the LLM/dreaming context
      # actually reads back).

      # ── Expected 4: 10 audit rows with kind memory.maintenance.link_repair. ─
      events =
        Audit.list(event_type: "platform.memory.maintenance.link_repair", limit: 50)

      assert length(events) == 10, "expected 10 audit rows, got #{length(events)}"

      Enum.each(events, fn event ->
        assert event.event_type == "platform.memory.maintenance.link_repair"
        assert event.actor_type == "agent"
        assert event.action == "link_repair"
        assert event.metadata["actor_slug"] == "historian.dreaming"
        assert event.metadata["outcome"] == "ok"
      end)

      recorded_targets =
        events
        |> Enum.map(& &1.metadata["target_path"])
        |> Enum.sort()

      expected_targets = Enum.map(1..10, fn i -> "dangling-#{i}" end) |> Enum.sort()

      assert recorded_targets == expected_targets,
             "audit rows do not cover all 10 items — missing or duplicated"
    end
  end
end
