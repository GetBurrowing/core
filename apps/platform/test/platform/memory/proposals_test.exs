defmodule Platform.Memory.ProposalsTest do
  @moduledoc """
  Coverage for the `<synthesis-proposal>` ingestion + status-transition
  API. Mirrors the fixture style of `Platform.Memory.IntegrityTest` —
  purge the target table in `setup` so per-test seed data doesn't leak.
  """
  use Platform.DataCase, async: false

  alias Platform.Audit
  alias Platform.Memory.MemoryProposal
  alias Platform.Memory.Proposals
  alias Platform.Org.Context, as: OrgContext
  alias Platform.Org.Wiki
  alias Platform.Memory.JournalSweep
  alias Platform.Org.Wiki.Journal
  alias Platform.Org.WikiPage
  alias Platform.Repo

  setup do
    Repo.delete_all(MemoryProposal)
    Repo.delete_all(WikiPage)
    Repo.delete_all(Platform.MemoryFeedback.Entry)
    Repo.delete_all(Platform.Audit.Event)
    :ok
  end

  # ── Sweep-hook predicate ─────────────────────────────────────────────

  describe "journal_path?/1" do
    test "matches org / project / space journal file_keys" do
      assert Proposals.journal_path?("org/journal/2026-07-17.md")
      assert Proposals.journal_path?("project/abc-123/journal/2026-07-17.md")
      assert Proposals.journal_path?("space/xyz-789/journal/2026-01-01.md")
    end

    test "rejects page keys, malformed dates, and non-strings" do
      refute Proposals.journal_path?("org/page/identity.md")
      refute Proposals.journal_path?("org/journal/2026-7-17.md")
      refute Proposals.journal_path?("org/journal/not-a-date.md")
      refute Proposals.journal_path?("random/thing.md")
      refute Proposals.journal_path?(nil)
      refute Proposals.journal_path?(:atom)
    end
  end

  # ── Happy-path parse + persist ───────────────────────────────────────

  describe "ingest_from_journal/3 — parse + persist" do
    test "parses a well-formed block into a pending proposal row" do
      content = ~s"""
      Today's raw notes.

      <synthesis-proposal category="recurring-theme" confidence="high" evidence="Rowan mentioned pricing anchors drifting in 3 separate journal entries this week.">
      Pricing anchors keep drifting when Rowan reviews SXI deliverables — the
      root cause looks like weekly reprioritization without an anchor doc.
      </synthesis-proposal>

      More notes below.
      """

      assert {:ok, 1} = Proposals.ingest_from_journal(nil, "org/journal/2026-07-17.md", content)

      [row] = Repo.all(MemoryProposal)
      assert row.status == "pending"
      assert row.category == "recurring-theme"
      assert row.confidence == "high"
      assert row.journal_path == "org/journal/2026-07-17.md"
      assert row.workspace_id == nil
      assert row.evidence =~ "pricing anchors drifting"
      assert row.body =~ "Pricing anchors keep drifting"
      assert is_binary(row.block_hash)
      assert byte_size(row.block_hash) == 64
    end

    test "parses multiple blocks in a single journal" do
      content = ~s"""
      <synthesis-proposal category="strategic-insight" confidence="medium" evidence="First evidence.">
      First body.
      </synthesis-proposal>

      <synthesis-proposal category="emerging-risk" confidence="low" evidence="Second evidence.">
      Second body.
      </synthesis-proposal>
      """

      assert {:ok, 2} = Proposals.ingest_from_journal(nil, "org/journal/2026-07-17.md", content)
      assert Repo.aggregate(MemoryProposal, :count) == 2
    end

    test "tolerates attribute reordering" do
      content = ~s"""
      <synthesis-proposal evidence="e1" confidence="high" category="unresolved-question">
      Some question body.
      </synthesis-proposal>
      """

      assert {:ok, 1} = Proposals.ingest_from_journal(nil, "org/journal/2026-07-17.md", content)
      assert [%{category: "unresolved-question"}] = Repo.all(MemoryProposal)
    end

    test "defaults expires_at to inserted_at + 7 days" do
      content = ~s"""
      <synthesis-proposal category="recurring-theme" confidence="high" evidence="e">
      Body.
      </synthesis-proposal>
      """

      assert {:ok, 1} = Proposals.ingest_from_journal(nil, "org/journal/2026-07-17.md", content)

      [row] = Repo.all(MemoryProposal)
      diff = DateTime.diff(row.expires_at, row.inserted_at, :second)
      # Allow +/- 5s slop for changeset put_default_expires_at anchoring
      # to `now` when inserted_at isn't yet stamped on the changeset.
      assert_in_delta diff, 7 * 86_400, 5
    end
  end

  # ── Idempotent re-ingest ─────────────────────────────────────────────

  describe "ingest_from_journal/3 — idempotency" do
    test "same block re-ingested is deduped by (workspace_id, block_hash)" do
      content = ~s"""
      <synthesis-proposal category="recurring-theme" confidence="high" evidence="e">
      Same body twice.
      </synthesis-proposal>
      """

      assert {:ok, 1} = Proposals.ingest_from_journal(nil, "org/journal/2026-07-17.md", content)
      assert {:ok, 0} = Proposals.ingest_from_journal(nil, "org/journal/2026-07-17.md", content)

      assert Repo.aggregate(MemoryProposal, :count) == 1
    end

    test "same body in different workspaces creates separate rows" do
      ws_a = Ecto.UUID.generate()
      ws_b = Ecto.UUID.generate()

      content = ~s"""
      <synthesis-proposal category="recurring-theme" confidence="high" evidence="e">
      Shared body.
      </synthesis-proposal>
      """

      assert {:ok, 1} = Proposals.ingest_from_journal(ws_a, "org/journal/2026-07-17.md", content)
      assert {:ok, 1} = Proposals.ingest_from_journal(ws_b, "org/journal/2026-07-17.md", content)

      assert Repo.aggregate(MemoryProposal, :count) == 2
    end
  end

  # ── Malformed input ──────────────────────────────────────────────────

  describe "ingest_from_journal/3 — malformed blocks" do
    test "block with missing category is skipped" do
      content = ~s"""
      <synthesis-proposal confidence="high" evidence="e">
      No category attr.
      </synthesis-proposal>
      """

      assert {:ok, 0} = Proposals.ingest_from_journal(nil, "org/journal/2026-07-17.md", content)
      assert Repo.aggregate(MemoryProposal, :count) == 0
    end

    test "block with unknown category is skipped" do
      content = ~s"""
      <synthesis-proposal category="not-a-real-category" confidence="high" evidence="e">
      Body.
      </synthesis-proposal>
      """

      assert {:ok, 0} = Proposals.ingest_from_journal(nil, "org/journal/2026-07-17.md", content)
    end

    test "block with unknown confidence is skipped" do
      content = ~s"""
      <synthesis-proposal category="recurring-theme" confidence="uncertain" evidence="e">
      Body.
      </synthesis-proposal>
      """

      assert {:ok, 0} = Proposals.ingest_from_journal(nil, "org/journal/2026-07-17.md", content)
    end

    test "block with empty body is skipped" do
      content = ~s"""
      <synthesis-proposal category="recurring-theme" confidence="high" evidence="e">
      </synthesis-proposal>
      """

      assert {:ok, 0} = Proposals.ingest_from_journal(nil, "org/journal/2026-07-17.md", content)
    end

    test "content with no blocks returns {:ok, 0}" do
      assert {:ok, 0} =
               Proposals.ingest_from_journal(nil, "org/journal/2026-07-17.md", "just prose")
    end

    test "nil content is treated as empty" do
      assert {:ok, 0} = Proposals.ingest_from_journal(nil, "org/journal/2026-07-17.md", nil)
    end

    test "well-formed blocks alongside malformed ones still ingest the well-formed" do
      content = ~s"""
      <synthesis-proposal category="not-real" confidence="high" evidence="e">
      Malformed.
      </synthesis-proposal>

      <synthesis-proposal category="strategic-insight" confidence="high" evidence="e">
      Well-formed.
      </synthesis-proposal>
      """

      assert {:ok, 1} = Proposals.ingest_from_journal(nil, "org/journal/2026-07-17.md", content)
      assert [%{body: "Well-formed."}] = Repo.all(MemoryProposal)
    end
  end

  # ── list_pending / expire_stale ──────────────────────────────────────

  describe "list_pending/1" do
    test "returns only pending rows, newest first" do
      insert_proposal!(body: "old", inserted_at: hours_ago(6))
      insert_proposal!(body: "newer", inserted_at: hours_ago(2))
      insert_proposal!(body: "approved", status: "approved")

      assert [%{body: "newer"}, %{body: "old"}] = Proposals.list_pending()
    end

    test "excludes expired rows even if status is still pending" do
      now = DateTime.utc_now()

      # Force expires_at into the past
      insert_proposal!(
        body: "stale",
        expires_at: DateTime.add(now, -60, :second)
      )

      insert_proposal!(body: "fresh")

      assert [%{body: "fresh"}] = Proposals.list_pending()
    end

    test "workspace_id filter scopes rows" do
      ws = Ecto.UUID.generate()
      insert_proposal!(body: "in-ws", workspace_id: ws)
      insert_proposal!(body: "no-ws")

      assert [%{body: "in-ws"}] = Proposals.list_pending(workspace_id: ws)
    end

    test ":limit caps the row count" do
      for i <- 1..10 do
        insert_proposal!(body: "row-#{i}", inserted_at: minutes_ago(i))
      end

      assert length(Proposals.list_pending(limit: 3)) == 3
    end
  end

  describe "expire_stale/0" do
    test "flips pending+past-expires rows to expired" do
      now = DateTime.utc_now()

      p_stale =
        insert_proposal!(
          body: "stale",
          expires_at: DateTime.add(now, -3600, :second)
        )

      p_fresh = insert_proposal!(body: "fresh")

      assert {1, _} = Proposals.expire_stale()

      assert %{status: "expired"} = Repo.get!(MemoryProposal, p_stale.id)
      assert %{status: "pending"} = Repo.get!(MemoryProposal, p_fresh.id)
    end

    test "does not touch approved / rejected rows even if past expires_at" do
      now = DateTime.utc_now()

      p_approved =
        insert_proposal!(
          body: "old-approved",
          status: "approved",
          expires_at: DateTime.add(now, -3600, :second)
        )

      p_rejected =
        insert_proposal!(
          body: "old-rejected",
          status: "rejected",
          expires_at: DateTime.add(now, -3600, :second)
        )

      assert {0, _} = Proposals.expire_stale()

      assert %{status: "approved"} = Repo.get!(MemoryProposal, p_approved.id)
      assert %{status: "rejected"} = Repo.get!(MemoryProposal, p_rejected.id)
    end
  end

  # ── approve / reject ─────────────────────────────────────────────────

  describe "approve/2 & reject/3" do
    test "approve/2 flips status to approved" do
      p = insert_proposal!(body: "approve me")

      assert {:ok, updated} = Proposals.approve(p)
      assert updated.status == "approved"
    end

    test "reject/3 captures feedback text" do
      p = insert_proposal!(body: "reject me")

      assert {:ok, updated} = Proposals.reject(p, "no bearing on the business")
      assert updated.status == "rejected"
      assert updated.feedback == "no bearing on the business"
    end

    test "reject/3 with nil feedback still transitions" do
      p = insert_proposal!(body: "reject me")

      assert {:ok, updated} = Proposals.reject(p, nil)
      assert updated.status == "rejected"
      assert updated.feedback == nil
    end
  end

  # ── rejected_exemplars ───────────────────────────────────────────────

  describe "rejected_exemplars/1" do
    test "returns most-recently-rejected rows as {body, feedback, category, rejected_at}" do
      p1 = insert_proposal!(body: "first", category: "strategic-insight")
      p2 = insert_proposal!(body: "second", category: "emerging-risk")
      _p3 = insert_proposal!(body: "still-pending")

      {:ok, _} = Proposals.reject(p1, "meh")
      {:ok, _} = Proposals.reject(p2, "not now")

      exemplars = Proposals.rejected_exemplars(limit: 5)

      assert length(exemplars) == 2
      # newest-rejected first (p2 was rejected after p1)
      [most_recent, older | _] = exemplars
      assert most_recent.body == "second"
      assert most_recent.feedback == "not now"
      assert most_recent.category == "emerging-risk"
      assert %DateTime{} = most_recent.rejected_at

      assert older.body == "first"
      assert older.feedback == "meh"
    end

    test ":limit caps the exemplar count" do
      for i <- 1..5 do
        p = insert_proposal!(body: "r-#{i}")
        {:ok, _} = Proposals.reject(p, "feedback-#{i}")
      end

      assert length(Proposals.rejected_exemplars(limit: 2)) == 2
    end

    test "returns [] when no rejected rows exist" do
      insert_proposal!(body: "still pending")
      assert [] = Proposals.rejected_exemplars()
    end
  end

  # ── Sweep-hook integration ───────────────────────────────────────────

  describe "OrgContext.upsert_context_file/3 sweep hook" do
    test "journal write with a synthesis-proposal block ingests a row" do
      content = ~s"""
      # Journal

      <synthesis-proposal category="recurring-theme" confidence="high" evidence="e">
      Ingested via the sweep hook.
      </synthesis-proposal>
      """

      assert {:ok, _} =
               OrgContext.upsert_context_file("org/journal/2026-07-17.md", %{
                 content: content,
                 updated_by: nil
               })

      assert [%{body: "Ingested via the sweep hook."}] = Repo.all(MemoryProposal)
    end

    test "page write with a synthesis-proposal block does NOT ingest" do
      content = ~s"""
      # Page

      <synthesis-proposal category="recurring-theme" confidence="high" evidence="e">
      Should be ignored — pages are not swept.
      </synthesis-proposal>
      """

      assert {:ok, _} =
               OrgContext.upsert_context_file("org/page/identity.md", %{
                 content: content,
                 updated_by: nil
               })

      assert [] = Repo.all(MemoryProposal)
    end

    test "journal write with no blocks does not create rows" do
      assert {:ok, _} =
               OrgContext.upsert_context_file("org/journal/2026-07-17.md", %{
                 content: "just prose today",
                 updated_by: nil
               })

      assert [] = Repo.all(MemoryProposal)
    end
  end

  describe "JournalSweep.sweep/2 after Journal.append/2" do
    test "journal append with a synthesis-proposal block ingests a row" do
      content = ~s"""
      Dreaming pass.

      <synthesis-proposal category="emerging-risk" confidence="high" evidence="org/journal/2026-07-17.md">
      Ingested via the journal append hook.
      </synthesis-proposal>
      """

      assert {:ok, _entry} =
               append_and_sweep(%{content: content, date: ~D[2026-07-17]}, "org")

      assert [%{body: "Ingested via the journal append hook.", category: "emerging-risk"}] =
               Repo.all(MemoryProposal)
    end

    test "namespaced append keys the proposal to the namespaced journal path" do
      workspace_id = Ecto.UUID.generate()

      content = ~s"""
      <synthesis-proposal category="unresolved-question" confidence="medium" evidence="e">
      Scoped to a project journal.
      </synthesis-proposal>
      """

      assert {:ok, _entry} =
               append_and_sweep(
                 %{content: content, date: ~D[2026-07-18], workspace_id: workspace_id},
                 "project/#{workspace_id}"
               )

      assert [%{journal_path: path, workspace_id: ^workspace_id}] = Repo.all(MemoryProposal)
      assert path == "project/#{workspace_id}/journal/2026-07-18.md"
    end

    test "append with no blocks does not create rows" do
      assert {:ok, _entry} =
               append_and_sweep(%{content: "just prose today", date: ~D[2026-07-17]}, "org")

      assert [] = Repo.all(MemoryProposal)
    end

    test "re-appending the same block does not duplicate the proposal" do
      content = ~s"""
      <synthesis-proposal category="recurring-theme" confidence="low" evidence="e">
      Written twice, ingested once.
      </synthesis-proposal>
      """

      assert {:ok, _} =
               append_and_sweep(%{content: content, date: ~D[2026-07-17]}, "org")

      assert {:ok, _} =
               append_and_sweep(%{content: content, date: ~D[2026-07-17]}, "org")

      assert [%{body: "Written twice, ingested once."}] = Repo.all(MemoryProposal)
    end

    # Mirrors what a journal writer must do: append, then sweep. The two
    # production writers (the `memory_create` tool surface and the
    # /org_memory journal pane) call exactly this pair.
    defp append_and_sweep(attrs, namespace) do
      case Journal.append(attrs, namespace: namespace) do
        {:ok, entry} ->
          :ok = JournalSweep.sweep(entry, namespace)
          {:ok, entry}

        other ->
          other
      end
    end

    test "raw Journal.append/2 without the sweep ingests nothing" do
      content = ~s"""
      <synthesis-proposal category="recurring-theme" confidence="high" evidence="e">
      Written under the low-level API.
      </synthesis-proposal>
      """

      assert {:ok, _} =
               Journal.append(%{content: content, date: ~D[2026-07-17]}, namespace: "org")

      # Deliberate: the T2 layering guard in wiki_t2_e2e_test.exs forbids a
      # Platform.Memory call site inside Journal, so the sweep is a
      # separate module callers invoke. This test pins that contract —
      # if Journal ever starts sweeping on its own, this fails and the
      # guard test above it should be revisited too.
      assert [] = Repo.all(MemoryProposal)
    end
  end

  # ── derive_target_page_key/3 ─────────────────────────────────────────

  describe "derive_target_page_key/3" do
    test "recurring-theme with pricing evidence lands on org/page/topics/pricing.md" do
      assert Proposals.derive_target_page_key(
               "recurring-theme",
               "Rowan mentioned pricing anchors drifting in 3 separate journal entries this week.",
               "Client pricing anchors keep drifting."
             ) == "org/page/topics/pricing.md"
    end

    test "strategic-insight lands under org/page/strategy/" do
      assert Proposals.derive_target_page_key(
               "strategic-insight",
               "Rowan noted the self-serve tier could bring in new revenue.",
               "self-serve tier is worth exploring."
             ) == "org/page/strategy/self.md"
    end

    test "unknown category falls through to misc" do
      assert String.starts_with?(
               Proposals.derive_target_page_key("no-such-category", "whatever", "body"),
               "org/page/misc/"
             )
    end

    test "falls back to first line of body when evidence is empty" do
      assert Proposals.derive_target_page_key(
               "recurring-theme",
               "",
               "canonical pricing anchors keep drifting week after week."
             ) == "org/page/topics/canonical.md"
    end

    test "falls back to hash-derived slug when nothing meaningful remains" do
      result = Proposals.derive_target_page_key("recurring-theme", "a", "the")
      assert String.starts_with?(result, "org/page/topics/untitled-")
      assert String.ends_with?(result, ".md")
    end
  end

  # ── target_page_key filled at ingest ─────────────────────────────────

  describe "ingest_from_journal/3 — target_page_key" do
    test "target_page_key is derived + persisted at ingest time" do
      content = ~s"""
      <synthesis-proposal category="recurring-theme" confidence="high" evidence="Rowan mentioned pricing anchors drifting in 3 separate journal entries this week.">
      Pricing anchors keep drifting.
      </synthesis-proposal>
      """

      assert {:ok, 1} = Proposals.ingest_from_journal(nil, "org/journal/2026-07-19.md", content)

      [row] = Repo.all(MemoryProposal)
      assert row.target_page_key == "org/page/topics/pricing.md"
    end
  end

  # ── queue_promotion/1 promotion pipeline ─────────────────────────────

  describe "queue_promotion/1" do
    test "appends body to existing target page (preserves prior content)" do
      {:ok, _} =
        Wiki.upsert_page("org/page/topics/pricing.md", %{content: "# Pricing\n\nCurrent notes."})

      {:ok, _} =
        OrgContext.upsert_context_file("org/journal/2026-07-19.md", %{
          content: ~s"""
          <synthesis-proposal category="recurring-theme" confidence="high" evidence="Rowan mentioned pricing anchors drifting.">
          Pricing anchors keep drifting when reviewing SXI deliverables.
          </synthesis-proposal>
          """,
          updated_by: nil
        })

      [row] = Repo.all(MemoryProposal)
      {:ok, approved} = Proposals.approve(row)
      assert :ok = Proposals.queue_promotion(approved)

      page = Wiki.get_page("org/page/topics/pricing.md")
      assert page.content =~ "# Pricing\n\nCurrent notes."
      assert page.content =~ "Pricing anchors keep drifting when reviewing SXI deliverables."
      assert page.content =~ "## Dreaming synthesis"
    end

    test "creates target page when none exists yet" do
      {:ok, _} =
        OrgContext.upsert_context_file("org/journal/2026-07-19.md", %{
          content: ~s"""
          <synthesis-proposal category="emerging-risk" confidence="high" evidence="dependency graph churn observed across five vendors.">
          Vendor lock-in exposure is climbing.
          </synthesis-proposal>
          """,
          updated_by: nil
        })

      [row] = Repo.all(MemoryProposal)
      {:ok, approved} = Proposals.approve(row)
      assert :ok = Proposals.queue_promotion(approved)

      page = Wiki.get_page(row.target_page_key)
      assert page, "expected #{row.target_page_key} to be created"
      assert page.content =~ "Vendor lock-in exposure is climbing."
    end

    test "strips only the matching <synthesis-proposal> block from the journal" do
      journal_body = ~s"""
      <synthesis-proposal category="recurring-theme" confidence="high" evidence="Rowan mentioned pricing anchors drifting.">
      Pricing block body.
      </synthesis-proposal>

      Intervening prose that should survive.

      <synthesis-proposal category="strategic-insight" confidence="medium" evidence="thoughts on federation.">
      Federation block body.
      </synthesis-proposal>
      """

      {:ok, _} =
        OrgContext.upsert_context_file("org/journal/2026-07-19.md", %{
          content: journal_body,
          updated_by: nil
        })

      rows = Repo.all(MemoryProposal)
      assert length(rows) == 2

      pricing = Enum.find(rows, &(&1.body == "Pricing block body."))
      {:ok, approved} = Proposals.approve(pricing)
      assert :ok = Proposals.queue_promotion(approved)

      journal = OrgContext.get_file("org/journal/2026-07-19.md")
      refute journal.content =~ "Pricing block body."
      assert journal.content =~ "Federation block body."
      assert journal.content =~ "Intervening prose that should survive."
    end

    test "records a platform.memory.proposal_promoted audit event with expected metadata" do
      {:ok, _} =
        OrgContext.upsert_context_file("org/journal/2026-07-19.md", %{
          content: ~s"""
          <synthesis-proposal category="recurring-theme" confidence="high" evidence="Rowan mentioned pricing anchors drifting.">
          Body for audit test.
          </synthesis-proposal>
          """,
          updated_by: nil
        })

      [row] = Repo.all(MemoryProposal)
      {:ok, approved} = Proposals.approve(row)
      assert :ok = Proposals.queue_promotion(approved)

      events = Audit.list(event_type: "platform.memory.proposal_promoted", limit: 5)
      assert length(events) == 1
      [event] = events

      assert event.actor_type == "agent"
      assert event.metadata["actor_slug"] == "historian.dreaming"
      assert event.metadata["proposal_id"] == row.id
      assert event.metadata["target_page_key"] == row.target_page_key
      assert event.metadata["source_journal_path"] == "org/journal/2026-07-19.md"
      assert event.metadata["block_hash"] == row.block_hash
    end

    test "is idempotent-friendly: promoting after journal block already stripped still succeeds" do
      {:ok, _} =
        OrgContext.upsert_context_file("org/journal/2026-07-19.md", %{
          content: ~s"""
          <synthesis-proposal category="recurring-theme" confidence="high" evidence="Rowan mentioned pricing anchors drifting.">
          Body to strip.
          </synthesis-proposal>
          """,
          updated_by: nil
        })

      [row] = Repo.all(MemoryProposal)
      {:ok, approved} = Proposals.approve(row)
      assert :ok = Proposals.queue_promotion(approved)

      # Second call: journal already stripped; page already augmented once;
      # audit row should still land (this is the "retry after transient
      # failure" scenario).
      assert :ok = Proposals.queue_promotion(approved)

      # The page will have been appended twice (retry pattern is
      # additive), but the point of this test is the pipeline doesn't
      # blow up when the block is already gone.
      assert length(Audit.list(event_type: "platform.memory.proposal_promoted", limit: 5)) == 2
    end
  end

  # ── Test helpers ─────────────────────────────────────────────────────

  defp insert_proposal!(overrides) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    body = Keyword.get(overrides, :body, "test body #{System.unique_integer([:positive])}")

    base = %{
      workspace_id: Keyword.get(overrides, :workspace_id),
      journal_path: "org/journal/2026-07-17.md",
      block_hash: hash("#{body}-#{System.unique_integer([:positive])}"),
      category: Keyword.get(overrides, :category, "recurring-theme"),
      confidence: Keyword.get(overrides, :confidence, "high"),
      evidence: "test evidence",
      body: body,
      status: Keyword.get(overrides, :status, "pending"),
      expires_at: Keyword.get(overrides, :expires_at, DateTime.add(now, 7 * 86_400, :second)),
      inserted_at: Keyword.get(overrides, :inserted_at, now),
      updated_at: now
    }

    Repo.insert!(struct(MemoryProposal, base))
  end

  defp hash(str) do
    :sha256 |> :crypto.hash(str) |> Base.encode16(case: :lower)
  end

  defp hours_ago(n) do
    DateTime.utc_now()
    |> DateTime.add(-n * 3600, :second)
    |> DateTime.truncate(:microsecond)
  end

  defp minutes_ago(n) do
    DateTime.utc_now()
    |> DateTime.add(-n * 60, :second)
    |> DateTime.truncate(:microsecond)
  end

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  # The 16-character case is the load-bearing one: `Ecto.UUID.cast/1` accepts
  # any 16-byte binary, so a test built from "higgins" alone is green against
  # the bug these guards fix.
  describe "UUID boundary: Proposals.get/1" do
    test "returns nil for a malformed phx-value-id rather than raising" do
      assert Proposals.get("higgins") == nil
      assert Proposals.get("higginshigginsxx") == nil
    end
  end
end
