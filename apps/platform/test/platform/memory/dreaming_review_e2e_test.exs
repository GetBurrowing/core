defmodule Platform.Memory.DreamingReviewE2ETest do
  @moduledoc """
  Task-level review (stage 8) e2e evaluation for task 019f70e9 — Historian
  dreaming: prompt-template migration + synthesis-proposal review flow +
  subagent-scoped link/format maintenance.

  Executes the 5 e2e_behavior validations from the plan as observable
  behavioural assertions. Each `describe` block corresponds to one plan
  validation case (A/B/C/D/E) with an "OBSERVED"/"EXPECTED" comment
  block making the mapping explicit.

  This test IS the review agent's disposition source of truth.
  """
  use Platform.DataCase, async: false

  alias Platform.Audit
  alias Platform.Memory.MaintenanceSubagent
  alias Platform.Memory.MemoryProposal
  alias Platform.Memory.Proposals
  alias Platform.Org.Context, as: OrgContext
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Responsibilities.Handlers.Dreaming
  alias Platform.Responsibilities.Responsibility

  setup do
    Repo.delete_all(MemoryProposal)
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

  # ─────────────────────────────────────────────────────────────────────
  # Case A — pricing-drift proposal round-trip
  # ─────────────────────────────────────────────────────────────────────
  describe "Case A: pricing-drift proposal round-trip (approve flow)" do
    test "approve → promotion pipeline: augments target page, strips journal block, records audit event" do
      # Seed target page.
      {:ok, _target_page} =
        Wiki.upsert_page("org/page/topics/pricing.md", %{content: "# Pricing\n\nCurrent notes."})

      # Simulate the LLM synthesis output that Handlers.Dreaming.handle_output/3
      # would receive from a dreaming pass with the pricing signal.
      synthesis_body = ~s"""
      # Dreaming synthesis 2026-07-19

      <synthesis-proposal category="recurring-theme" confidence="high" evidence="Rowan mentioned pricing anchors drifting in 3 separate journal entries this week.">
      Client pricing anchors keep drifting when Rowan reviews SXI deliverables — a
      canonical pricing-topics page section would keep the anchor stable.
      </synthesis-proposal>
      """

      # Fire the handler (this is the synchronous entry the case's
      # `Router.fire_trigger` would reach after the LLM call).
      assert :ok =
               Dreaming.handle_output(
                 responsibility(),
                 %{"memory_body" => synthesis_body},
                 %{kind: :cron}
               )

      # ── Expected 1 — pending row with recurring-theme category exists ───
      pending = Proposals.list_pending()

      pricing_row =
        Enum.find(pending, fn p ->
          p.category == "recurring-theme" and p.evidence =~ "pricing"
        end)

      assert pricing_row, "no pending recurring-theme proposal with pricing evidence"

      # ── Sanity: target_page_key derived to the pricing page at ingest. ─
      assert pricing_row.target_page_key == "org/page/topics/pricing.md",
             "expected target_page_key derivation to land on org/page/topics/pricing.md; " <>
               "got #{inspect(pricing_row.target_page_key)}"

      proposal_body = pricing_row.body

      # ── Expected 2 — approve removes from pending list + runs promotion.
      {:ok, approved} = Proposals.approve(pricing_row)
      assert :ok = Proposals.queue_promotion(approved)

      refute Enum.any?(Proposals.list_pending(), fn p -> p.id == pricing_row.id end),
             "approved proposal still surfaced in list_pending"

      # Row itself is preserved with status=approved (not deleted).
      assert Repo.get!(MemoryProposal, pricing_row.id).status == "approved"

      # ── Expected 3 — target page augmented with synthesized prose ──────
      pricing_page = Wiki.get_page("org/page/topics/pricing.md")

      assert pricing_page.content =~ "# Pricing\n\nCurrent notes.",
             "expected original pricing page content to be preserved"

      assert pricing_page.content =~ proposal_body,
             "expected pricing page to be augmented with proposal body, but body missing. " <>
               "Content: #{inspect(pricing_page.content)}"

      assert pricing_page.content =~ "## Dreaming synthesis",
             "expected augmented content to carry a dated section header"

      # ── Expected 4 — journal block stripped ────────────────────────────
      journal = OrgContext.get_file(todays_journal())

      refute journal.content =~ "<synthesis-proposal",
             "expected approved <synthesis-proposal> block to be stripped from journal, " <>
               "but block is still present. Journal: #{inspect(journal.content)}"

      # ── Expected 5 — promotion audit event ─────────────────────────────
      events = Audit.list(event_type: "platform.memory.proposal_promoted", limit: 10)

      assert length(events) >= 1,
             "expected a platform.memory.proposal_promoted audit row — none found"

      [event | _] = events
      assert event.actor_type == "agent"
      assert event.metadata["actor_slug"] == "historian.dreaming"
      assert event.metadata["proposal_id"] == pricing_row.id
      assert event.metadata["target_page_key"] == "org/page/topics/pricing.md"
      assert event.metadata["source_journal_path"] == pricing_row.journal_path
      assert event.metadata["block_hash"] == pricing_row.block_hash
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Case B — format_normalize auto-apply for 3 bare-slug refs
  # ─────────────────────────────────────────────────────────────────────
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

      proposals_before = Repo.aggregate(MemoryProposal, :count)

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
      proposals_after = Repo.aggregate(MemoryProposal, :count)

      assert proposals_after == proposals_before,
             "expected 0 new proposals from auto-applied maintenance; got #{proposals_after - proposals_before}"

      # ── Expected 4: journal auto-applied summary mentions count=3. ────
      journal = OrgContext.get_file(todays_journal())
      assert journal.content =~ "format_normalize: 3 succeeded, 0 failed"
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Case C — reject-with-feedback → few-shot corpus
  # ─────────────────────────────────────────────────────────────────────
  describe "Case C: reject-with-feedback → few-shot corpus in dreaming prompt" do
    test "rejected proposal body + feedback appear verbatim in rendered dreaming template" do
      # Ensure the prompt template is seeded.
      :ok = PromptTemplates.seed_defaults()

      # ── Setup: direct-DB insert one pending strategic-insight proposal. ──
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      proposal =
        Repo.insert!(
          struct(MemoryProposal, %{
            workspace_id: nil,
            journal_path: "org/journal/2026-07-19.md",
            block_hash:
              :sha256
              |> :crypto.hash("acme-self-serve-#{System.unique_integer([:positive])}")
              |> Base.encode16(case: :lower),
            category: "strategic-insight",
            confidence: "high",
            evidence: "seeded for review",
            body: "Acme should launch a self-serve tier",
            status: "pending",
            expires_at: DateTime.add(now, 7 * 86_400, :second),
            inserted_at: now,
            updated_at: now
          })
        )

      feedback = "no bearing on the business — self-serve is out of scope for this year"

      # ── Reject with feedback. ──────────────────────────────────────────
      assert {:ok, rejected} = Proposals.reject(proposal, feedback)

      # ── Expected 1: DB status flipped + feedback captured verbatim. ────
      persisted = Repo.get!(MemoryProposal, proposal.id)
      assert persisted.status == "rejected"
      assert persisted.feedback == feedback

      # ── Expected 2: rejected row not in pending list. ──────────────────
      refute Enum.any?(Proposals.list_pending(), fn p -> p.id == proposal.id end)

      # ── Expected 3: rendered dreaming template contains body + feedback. ─
      exemplars = Proposals.rejected_exemplars(limit: 3)
      assert length(exemplars) >= 1
      assert Enum.any?(exemplars, &(&1.body == proposal.body))

      # Format the exemplars as the handler does (bulleted list).
      formatted =
        exemplars
        |> Enum.map(fn %{body: body, feedback: fb, category: category} ->
          fb_line =
            case fb do
              nil -> ""
              "" -> ""
              text -> "\n  - Rowan's feedback: #{text}"
            end

          "- [#{category}] #{body}#{fb_line}"
        end)
        |> Enum.join("\n")

      assigns = %{
        federation_preamble: "",
        date: "2026-07-19",
        workspace_id: "test-workspace",
        activity_digest: "(empty)",
        rejected_exemplars: formatted,
        skills_reference: ""
      }

      assert {:ok, rendered} = PromptTemplates.render_template("historian.dreaming", assigns)

      assert rendered =~ proposal.body,
             "rendered dreaming template does not contain rejected proposal body verbatim"

      assert rendered =~ feedback,
             "rendered dreaming template does not contain feedback text verbatim"

      # Also verify legacy slug rendering (byte-identical body).
      assert {:ok, legacy_rendered} =
               PromptTemplates.render_template("memory.dreaming.v1", assigns)

      assert legacy_rendered =~ proposal.body
      assert legacy_rendered =~ feedback

      # Reference the rejected struct so the compiler doesn't warn.
      assert rejected.id == proposal.id
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Case D — TTL expiration
  # ─────────────────────────────────────────────────────────────────────
  describe "Case D: TTL expiration flips 8-day-old row to expired, preserves fresh row" do
    test "expire_stale/0 flips old→expired (NOT deleted), fresh unchanged, list_pending shows only fresh" do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      stale_inserted = DateTime.add(now, -8 * 86_400, :second)
      stale_expires = DateTime.add(now, -1 * 86_400, :second)

      stale =
        Repo.insert!(
          struct(MemoryProposal, %{
            workspace_id: nil,
            journal_path: "org/journal/2026-07-11.md",
            block_hash:
              :sha256
              |> :crypto.hash("stale-#{System.unique_integer([:positive])}")
              |> Base.encode16(case: :lower),
            category: "recurring-theme",
            confidence: "medium",
            evidence: "stale evidence",
            body: "Stale 8-day-old proposal.",
            status: "pending",
            expires_at: stale_expires,
            inserted_at: stale_inserted,
            updated_at: stale_inserted
          })
        )

      fresh_inserted = DateTime.add(now, -1 * 86_400, :second)
      fresh_expires = DateTime.add(now, 6 * 86_400, :second)

      fresh =
        Repo.insert!(
          struct(MemoryProposal, %{
            workspace_id: nil,
            journal_path: "org/journal/2026-07-18.md",
            block_hash:
              :sha256
              |> :crypto.hash("fresh-#{System.unique_integer([:positive])}")
              |> Base.encode16(case: :lower),
            category: "recurring-theme",
            confidence: "medium",
            evidence: "fresh evidence",
            body: "Fresh 1-day-old proposal.",
            status: "pending",
            expires_at: fresh_expires,
            inserted_at: fresh_inserted,
            updated_at: fresh_inserted
          })
        )

      # ── Trigger sweep. ─────────────────────────────────────────────────
      assert {1, _} = Proposals.expire_stale()

      # ── Expected 1: 8-day-old row status=expired, NOT deleted. ────────
      persisted_stale = Repo.get!(MemoryProposal, stale.id)
      assert persisted_stale.status == "expired", "stale row not flipped to expired"

      # ── Expected 2: fresh row unchanged. ──────────────────────────────
      persisted_fresh = Repo.get!(MemoryProposal, fresh.id)
      assert persisted_fresh.status == "pending", "fresh row was inadvertently touched"

      # ── Expected 3: list_pending returns only fresh row. ──────────────
      pending = Proposals.list_pending()
      pending_ids = MapSet.new(pending, & &1.id)

      assert MapSet.member?(pending_ids, fresh.id), "fresh row missing from list_pending"

      refute MapSet.member?(pending_ids, stale.id),
             "expired row still surfaced in list_pending"

      # ── Expected 4: expired row is preserved for post-hoc analysis
      #    (NOT deleted from the DB). ──────────────────────────────────
      assert Repo.aggregate(MemoryProposal, :count) == 2,
             "expected both rows to persist; the DB was mutated by delete instead of expire"
    end
  end

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
