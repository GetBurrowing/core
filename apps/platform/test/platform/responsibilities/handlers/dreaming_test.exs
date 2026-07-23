defmodule Platform.Responsibilities.Handlers.DreamingTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.Dreaming` — the M8
  stage 2 provider that owns the `memory.dreaming` responsibility row.

  Stage 7 rewired `handle_output/3`:

    * NEVER writes to `org/page/*` file_keys (proposal-review pipeline
      gates page mutations).
    * Writes the LLM synthesis output to today's `org/journal/…md` so
      the sweep hook can materialise `<synthesis-proposal>` blocks.
    * Runs `Platform.Memory.Integrity.scan/1` and dispatches the
      corresponding `MaintenanceSubagent.spawn_*` fan-outs. Op counts
      are appended to the journal body under
      `## Auto-applied maintenance`.
    * The per-op audit trail lives on
      `platform.memory.maintenance.*` events (covered by
      `MaintenanceSubagentTest` — here we assert the journal counts
      match the fan-out).
  """
  use Platform.DataCase, async: false

  alias Platform.Audit
  alias Platform.Memory.MemoryProposal
  alias Platform.Org.Context, as: OrgContext
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Responsibilities.Handlers.Dreaming
  alias Platform.Responsibilities.Responsibility

  setup do
    Repo.delete_all(MemoryProposal)
    Repo.delete_all(WikiPage)
    Repo.delete_all(Platform.MemoryFeedback.Entry)
    :ok
  end

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: Dreaming.key(),
      feature: "memory",
      trigger_kind: "cron",
      trigger_config: %{
        "expression" => "0 5 * * *",
        "timezone" => "America/Chicago"
      },
      scope: "per_org",
      context_provided: ["recent_journal", "org_identity"],
      enabled: true
    }
  end

  defp todays_journal, do: Dreaming.journal_file_key(Date.utc_today())

  # A snapshot of every WikiPage.file_key that starts with "org/page/"
  # before + after the handler runs — makes the "no page write" invariant
  # a first-class assertion.
  defp page_signatures do
    from(p in WikiPage, where: like(p.file_key, "org/page/%"), select: {p.file_key, p.version})
    |> Repo.all()
    |> MapSet.new()
  end

  describe "register/0" do
    test "declares one spec with the canonical key + timezone-aware cron expression" do
      [spec] = Dreaming.register()

      assert spec.key == "memory.dreaming"
      assert spec.feature == "memory"
      assert spec.trigger_kind == "cron"

      assert spec.trigger_config == %{
               "expression" => "0 5 * * *",
               "timezone" => "America/Chicago"
             }

      assert spec.scope == "per_org"
      assert spec.context_provided == ["recent_journal", "org_identity"]

      # Stage 7: metadata advertises the journal target, no direct page.
      assert spec.metadata["target_kind"] == "journal"
      assert spec.metadata["target_prefix"] == "org/journal/"
      refute Map.has_key?(spec.metadata, "target_file_key")
    end
  end

  describe "handle_output/3 — journal writes" do
    test "writes LLM synthesis body to today's journal file_key" do
      body = "# Notes\n\nSome synthesis for today."

      assert :ok =
               Dreaming.handle_output(
                 responsibility(),
                 %{"memory_body" => body},
                 %{kind: :cron}
               )

      file = OrgContext.get_file(todays_journal())
      assert file
      assert file.content =~ "Some synthesis for today."
      assert file.content =~ "Auto-applied maintenance"
    end

    test "accepts %{\"summary\" => ...} alias too" do
      assert :ok =
               Dreaming.handle_output(
                 responsibility(),
                 %{"summary" => "alt-key payload"},
                 %{kind: :cron}
               )

      file = OrgContext.get_file(todays_journal())
      assert file.content =~ "alt-key payload"
    end

    test "accepts a bare string" do
      assert :ok =
               Dreaming.handle_output(
                 responsibility(),
                 "bare body",
                 %{kind: :cron}
               )

      assert OrgContext.get_file(todays_journal()).content =~ "bare body"
    end

    test "rejects malformed output" do
      assert {:error, :invalid_output_shape} =
               Dreaming.handle_output(responsibility(), %{}, %{kind: :cron})

      assert {:error, :invalid_output_shape} =
               Dreaming.handle_output(responsibility(), %{"memory_body" => ""}, %{kind: :cron})
    end

    test "repeat fires bump the journal version" do
      assert :ok =
               Dreaming.handle_output(
                 responsibility(),
                 %{"memory_body" => "v1 body"},
                 %{kind: :cron}
               )

      v1 = OrgContext.get_file(todays_journal()).version

      assert :ok =
               Dreaming.handle_output(
                 responsibility(),
                 %{"memory_body" => "v2 body"},
                 %{kind: :cron}
               )

      v2 = OrgContext.get_file(todays_journal()).version
      assert v2 > v1
    end
  end

  # ── LOAD-BEARING invariant: no page writes from the dreaming handler ──

  describe "acceptance criterion 2 — never touches org/page/* file_keys" do
    test "handle_output/3 leaves page rows untouched even with maintenance-flavoured input" do
      # Seed a page world so any accidental page mutation would be
      # visible in the before/after snapshot.
      {:ok, _} = Wiki.upsert_page("org/page/identity.md", %{content: "identity anchor"})
      {:ok, _} = Wiki.upsert_page("org/page/memory.md", %{content: "existing memory page"})
      {:ok, _} = Wiki.upsert_page("org/page/agents.md", %{content: "agent registry"})

      before = page_signatures()

      # Simulate the LLM emitting a synthesis-flavoured body that
      # explicitly mentions the legacy write target — a naive handler
      # rewrite would still land on `org/page/memory.md`.
      body =
        """
        # Overnight synthesis
        Learned: pricing anchors keep drifting.

        <synthesis-proposal category="recurring-theme" confidence="high" evidence="entries from 07-15..07-18">
        Pricing anchors keep drifting when Rowan reviews SXI deliverables.
        </synthesis-proposal>
        """

      assert :ok =
               Dreaming.handle_output(
                 responsibility(),
                 %{"memory_body" => body},
                 %{kind: :cron}
               )

      # Page snapshot must be identical (same file_keys + same versions).
      assert page_signatures() == before,
             "handle_output/3 mutated an org/page/* file — page writes must flow through /memory/proposals only"

      # And the journal DID pick up the write.
      journal = OrgContext.get_file(todays_journal())
      assert journal, "expected today's journal to be written"
      assert journal.content =~ "Overnight synthesis"
    end
  end

  # ── Maintenance fan-out + proposal ingestion ─────────────────────────

  describe "handle_output/3 — synthesis + maintenance side effects" do
    test "synthesis-proposal blocks in LLM output land in memory_proposals via sweep hook" do
      body =
        """
        # Today's synthesis

        <synthesis-proposal category="cross-project-pattern" confidence="medium" evidence="Suite + Orion both adopting the same brand-token vocabulary this week">
        Both Suite and Orion are converging on a semantic-token
        vocabulary for brand palette references — worth naming so
        neither project reinvents it.
        </synthesis-proposal>
        """

      assert :ok =
               Dreaming.handle_output(
                 responsibility(),
                 %{"memory_body" => body},
                 %{kind: :cron}
               )

      # The sweep hook fired inside `upsert_context_file/3`'s post-write
      # tap and materialised the proposal row.
      [proposal] = Repo.all(MemoryProposal)
      assert proposal.status == "pending"
      assert proposal.category == "cross-project-pattern"
      assert proposal.journal_path == todays_journal()
    end

    test "maintenance fan-out runs off Integrity.scan output and records audit rows" do
      # Seed a corpus with a `:format_dirty` link (bare basename that
      # resolves unambiguously). The Integrity scan will surface it,
      # the format_normalize subagent will rewrite it, and the fan-out
      # counter will register 1 success.
      {:ok, _target} = Wiki.upsert_page("org/page/identity.md", %{content: "identity anchor"})

      {:ok, _source} =
        Wiki.upsert_page("org/page/notes.md", %{content: "See [[identity]] for detail."})

      assert :ok =
               Dreaming.handle_output(
                 responsibility(),
                 %{"memory_body" => "# Dream body"},
                 %{kind: :cron}
               )

      # The subagent recorded exactly one audit row for the rewrite.
      events =
        Audit.list(event_type: "platform.memory.maintenance.format_normalize", limit: 10)

      assert length(events) == 1
      [event] = events
      assert event.metadata["outcome"] == "ok"
      assert event.metadata["source_path"] == "org/page/notes.md"
      assert event.metadata["target_path"] == "identity"
      assert event.metadata["resolved_target_path"] == "org/page/identity.md"

      # Journal summary section reflects the count.
      journal = OrgContext.get_file(todays_journal())
      assert journal.content =~ "format_normalize: 1 succeeded"
      assert journal.content =~ "link_repair:      0 succeeded"
      assert journal.content =~ "retired_cleanup:  0 succeeded"
    end

    test "empty integrity scan renders zero-count maintenance summary without crashing" do
      # No pages seeded → nothing dangling → all three buckets empty.
      assert :ok =
               Dreaming.handle_output(
                 responsibility(),
                 %{"memory_body" => "Clean dream"},
                 %{kind: :cron}
               )

      journal = OrgContext.get_file(todays_journal())
      assert journal.content =~ "link_repair:      0 succeeded, 0 failed"
      assert journal.content =~ "format_normalize: 0 succeeded, 0 failed"
      assert journal.content =~ "retired_cleanup:  0 succeeded, 0 failed"
    end
  end

  describe "gather_context/2" do
    test "merges :recent_journal and :org_identity slots" do
      assert {:ok, ctx} = Dreaming.gather_context(responsibility(), %{})
      assert Map.has_key?(ctx, :recent_journal)
      assert Map.has_key?(ctx, :org_identity)
      assert Map.has_key?(ctx, :rejected_exemplars)
    end
  end

  describe "journal_file_key/1" do
    test "returns the canonical org journal path for a given date" do
      assert Dreaming.journal_file_key(~D[2026-07-19]) == "org/journal/2026-07-19.md"
      assert Dreaming.journal_file_key(~D[2026-01-01]) == "org/journal/2026-01-01.md"
    end
  end
end
