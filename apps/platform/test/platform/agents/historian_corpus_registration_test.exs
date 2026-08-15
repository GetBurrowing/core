defmodule Platform.Agents.HistorianCorpusRegistrationTest do
  @moduledoc """
  The six-site corpus registration checklist (task `01a0008c` stage 4).

  ## If you are adding a Historian corpus, this is the one thing to run

  A corpus must be registered in **six** places. Every one of them
  degrades *silently* when it is missed — not one raises, not one logs,
  and the sweep keeps returning `:ok`:

    1. `Platform.Agents.Historian.@corpora` — the corpus is never summed,
       never cursored, never sliced.
    2. `Platform.Agents.HistorianCursor.@valid_corpora` — **the worst
       one.** `Historian.mark_run_started/1` wraps its per-corpus upsert
       in an `Enum.each` inside a `Repo.transaction` and discards the
       `{:error, changeset}` this `validate_inclusion` produces, then
       returns `:ok`. The cursor row is never written,
       `cursor_last_processed_at/2` keeps returning `nil`, and the corpus
       **re-dispatches its entire history on every pass, forever**. See
       the dedicated tests at the bottom of this file, which is where
       that behaviour is proven rather than asserted about.
    3. `Platform.Agents.HistorianDispatcher.@corpus_order` — the corpus
       is still counted by `Historian.pending_bytes/1` (so the threshold
       fires *more* often) but is never sliced into a window. The
       Historian wakes up to digest nothing.
    4. `Platform.Agents.ActivityDigest.@corpora` — `corpus_items/4` falls
       through to `[]`, `windowed_body/4` to `_(unknown corpus)_`, and
       `corpus_heading/1` renders the raw atom.
    5. `Platform.Agents.HistorianAudit.raw_row_count/3` — falls through
       to `0`, so the audit reports a busy corpus empty and every
       oversize window in it classifies `:spurious`.
    6. `Mix.Tasks.Platform.HistorianAuditOversize`'s `--corpus` docs —
       the flag still filters, but the operator debugging that corpus
       never learns it is accepted.

  ## Why ONE test and not six

  Six assertions scattered across six files is a checklist a future
  corpus author finds five of. `registration_sites/0` below is the whole
  list in one place, and the failure message names every site that is
  missing the corpus.

  ## Why this is not a tautology

  `"every site reports registered"` would pass just as well if the checks
  were `fn _ -> true end`. So the same six checks are run a second time
  against `@unregistered_corpus`, a name that is deliberately registered
  nowhere, and **all six must report it missing**. A check that cannot
  fail is caught by that test, not by review.
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.TenancyFixtures

  alias Platform.Agents.ActivityDigest
  alias Platform.Agents.Historian
  alias Platform.Agents.HistorianAudit
  alias Platform.Agents.HistorianCursor
  alias Platform.Agents.HistorianDispatcher
  alias Platform.Files
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Repo
  alias Platform.Tasks

  # The corpus this stage registers.
  @corpus "files"

  # Registered nowhere, on purpose. The negative control below asserts
  # that every one of the six checks reports THIS as missing — which is
  # what makes a green run of the checklist mean something.
  @unregistered_corpus "not-a-corpus"

  # A quiet historical window, so the seeded rows are the only rows in it
  # regardless of what else the shared test database carries.
  @window_start ~U[2001-05-01 00:00:00.000000Z]
  @window_end ~U[2001-05-02 00:00:00.000000Z]
  @row_at ~U[2001-05-01 12:00:00.000000Z]

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Corpus Registration"})

    card =
      seed_card_page(project, "quarterly-report", "The Q3 revenue report. CARD-MARKER-A.")

    plain = seed_plain_page("org/page/registration-plain.md", "An ordinary wiki page.")

    {:ok, project: project, card: card, plain: plain}
  end

  # ── THE CHECKLIST ────────────────────────────────────────────────────────

  describe "corpus registration" do
    test "`files` is registered at all six sites" do
      sites = registration_sites()

      # The list itself is pinned. A site deleted from `registration_sites/0`
      # would otherwise make this test pass by shrinking.
      assert length(sites) == 6

      missing =
        for {site, check} <- sites, not check.(@corpus), do: site

      assert missing == [],
             """
             The corpus #{inspect(@corpus)} is NOT registered at #{length(missing)} of
             the 6 required sites. Each of these fails silently — the sweep
             returns :ok and logs nothing:

             #{Enum.map_join(missing, "\n", &("  * " <> &1))}

             Read the moduledoc of this test file for what each omission does
             at runtime before deciding which one to fix.
             """
    end

    test "the six checks can actually fail — an unregistered corpus fails every one" do
      sites = registration_sites()

      registered =
        for {site, check} <- sites, check.(@unregistered_corpus), do: site

      assert registered == [],
             """
             #{length(registered)} of the six registration checks reported the
             deliberately-unregistered corpus #{inspect(@unregistered_corpus)} as
             REGISTERED. Those checks are tautologies: they would stay green
             with their site emptied out, so the checklist above is decorative
             for them.

             Tautological checks:

             #{Enum.map_join(registered, "\n", &("  * " <> &1))}
             """
    end
  end

  # Site name → `(corpus_string -> boolean)`. Every check probes its own
  # site's real surface; none reads another site's answer, or the six
  # would collapse into one.
  defp registration_sites do
    [
      {"1. `Platform.Agents.Historian.@corpora` (agents/historian.ex) — " <>
         "the corpus is never summed, cursored or sliced",
       fn corpus ->
         corpus in Historian.corpora() and
           Map.has_key?(Historian.pending_windows_input(nil), String.to_atom(corpus))
       end},
      {"2. `Platform.Agents.HistorianCursor.@valid_corpora` (agents/historian_cursor.ex) — " <>
         "`mark_run_started/1` swallows the changeset error and the corpus " <>
         "re-dispatches its whole history on every pass, forever",
       fn corpus ->
         corpus in HistorianCursor.valid_corpora() and
           HistorianCursor.changeset(%HistorianCursor{}, %{corpus: corpus}).valid?
       end},
      {"3. `Platform.Agents.HistorianDispatcher.@corpus_order` " <>
         "(agents/historian_dispatcher.ex) — counted toward the threshold, " <>
         "never sliced into a window", fn corpus -> slicer_emits_window?(corpus) end},
      {"4. `Platform.Agents.ActivityDigest.@corpora` (agents/activity_digest.ex) — " <>
         "`corpus_items/4` returns [], the body renders `_(unknown corpus)_` " <>
         "and the heading renders the raw atom", fn corpus -> digest_renders_corpus?(corpus) end},
      {"5. `Platform.Agents.HistorianAudit.raw_row_count/3` (agents/historian_audit.ex) — " <>
         "falls through to 0, so the audit reports a busy corpus empty",
       fn corpus ->
         HistorianAudit.raw_row_count(corpus, @window_start, @window_end) > 0
       end},
      {"6. `mix platform.historian_audit_oversize --corpus` docs " <>
         "(lib/mix/tasks/platform/historian_audit_oversize.ex) — the flag " <>
         "filters but the corpus is undiscoverable",
       fn corpus -> audit_task_moduledoc() =~ "`#{corpus}`" end}
    ]
  end

  # Site 3. Drives the real slicer with a stubbed input keyed on this
  # corpus only. `slice_windows/2` folds over `@corpus_order`, so a corpus
  # missing from that list yields no window no matter what the input says.
  defp slicer_emits_window?(corpus) do
    now = DateTime.utc_now()
    last_at = DateTime.add(now, -3_600, :second)
    atom = String.to_atom(corpus)

    nil
    |> HistorianDispatcher.slice_windows(
      now: now,
      budget_tokens: 30_000,
      input_fn: fn _ws -> %{atom => {last_at, 20_000}} end
    )
    |> Enum.any?(&(&1.corpus == atom))
  end

  # Site 4. Three of `ActivityDigest`'s four corpus sub-sites at once,
  # against a window that really does hold a row of this corpus:
  #
  #   * `corpus_items/4` has a clause (else `[]`);
  #   * `@corpora` lists it, so `windowed_body/4` does not fall through to
  #     `_(unknown corpus)_`;
  #   * `corpus_heading/1` has a clause (else the header is the raw name).
  #
  # `render_corpus/2` is covered implicitly and hard: the seeded row is
  # inside the budget, so a missing clause raises FunctionClauseError here
  # rather than returning a wrong boolean.
  defp digest_renders_corpus?(corpus) do
    items = ActivityDigest.corpus_items(corpus, @window_start, @window_end)

    body =
      ActivityDigest.build_windowed(%{
        corpus: String.to_atom(corpus),
        window_start: @window_start,
        window_end: @window_end
      })

    items != [] and
      not String.contains?(body, "_(unknown corpus)_") and
      not String.contains?(body, "## #{corpus} since")
  end

  defp audit_task_moduledoc do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} =
      Code.fetch_docs(Mix.Tasks.Platform.HistorianAuditOversize)

    doc
  end

  # ── The cursor site is load-bearing: proof, not assertion ────────────────

  describe "the silence `@valid_corpora` buys (site 2)" do
    # THE ANTI-VACUITY TEST. Remove `"files"` from
    # `HistorianCursor.@valid_corpora` and leave the other five sites
    # registered: `mark_run_started/1` still returns `:ok`, still logs
    # nothing, and simply does not write the row. This test is the only
    # thing between that and a corpus that re-digests its entire history
    # every pass in production.
    test "mark_run_started/1 returns :ok and writes one cursor row per registered corpus" do
      assert :ok == Historian.mark_run_started(nil)

      written =
        HistorianCursor
        |> where([c], is_nil(c.workspace_id))
        |> select([c], c.corpus)
        |> Repo.all()
        |> Enum.sort()

      # POSITIVE CONTROL FIRST: an empty `written` would satisfy a bare
      # `refute` and say nothing.
      refute Enum.empty?(written)

      assert @corpus in written,
             """
             `Historian.mark_run_started/1` returned :ok and wrote NO cursor
             row for #{inspect(@corpus)}.

             That is the silent failure this stage exists to pin.
             `mark_run_started/1` runs `upsert_run_marker/3` inside an
             `Enum.each`, which discards the `{:error, changeset}` that
             `HistorianCursor.changeset/2`'s `validate_inclusion(:corpus, …)`
             returns for an unregistered corpus. Nothing raises, nothing is
             logged, and `:ok` comes back.

             Downstream: `cursor_last_processed_at(_, "#{@corpus}")` returns
             nil forever, so the slicer re-dispatches the corpus's ENTIRE
             history on every pass.

             Add #{inspect(@corpus)} to
             `Platform.Agents.HistorianCursor.@valid_corpora`.

             Wrote rows for: #{inspect(written)}
             """

      assert written == Enum.sort(Historian.corpora()),
             "one cursor row per corpus in `Historian.corpora/0` — got #{inspect(written)}"
    end

    # The mechanism itself, stated where it cannot be argued with: an
    # invalid corpus produces an error changeset that never reaches the
    # database, so the enclosing transaction commits cleanly and the
    # caller sees success.
    test "an unregistered corpus produces an error changeset that Enum.each discards" do
      changeset =
        HistorianCursor.changeset(%HistorianCursor{}, %{
          corpus: @unregistered_corpus,
          last_run_at: DateTime.utc_now()
        })

      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:corpus]

      # The shape `mark_run_started/1` uses: the error is the return value
      # of `Repo.insert/2`, and `Enum.each/2` throws return values away.
      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 Enum.each([@unregistered_corpus], fn corpus ->
                   %HistorianCursor{}
                   |> HistorianCursor.changeset(%{
                     corpus: corpus,
                     last_run_at: DateTime.utc_now()
                   })
                   |> Repo.insert(
                     on_conflict: [set: [last_run_at: DateTime.utc_now()]],
                     conflict_target: [:workspace_id, :corpus]
                   )
                 end)
               end)

      assert Repo.aggregate(
               from(c in HistorianCursor, where: c.corpus == ^@unregistered_corpus),
               :count
             ) == 0
    end
  end

  # ── The pages / files partition (the byte-weighting decision) ────────────

  describe "a card is charged to exactly one corpus" do
    test "the card is in `files` and the plain page is in `pages`, at every site",
         %{card: card, plain: plain} do
      files_items = ActivityDigest.corpus_items("files", @window_start, @window_end)
      pages_items = ActivityDigest.corpus_items("pages", @window_start, @window_end)

      # POSITIVE CONTROLS: both corpora non-empty, so the exclusions below
      # are a partition and not an empty-set identity.
      assert Enum.map(files_items, & &1.id) == [card.id]
      assert Enum.map(pages_items, & &1.id) == [plain.id]

      # The four Historian byte-signal sites, both workspace variants
      # reached through the org-scope sentinel coercion.
      card_bytes = byte_size(card.content)
      plain_bytes = byte_size(plain.content)

      assert Historian.pending_bytes_in_range("files", @window_start, @window_end) == card_bytes
      assert Historian.pending_bytes_in_range("pages", @window_start, @window_end) == plain_bytes

      assert Historian.pending_bytes_per_day("files", @window_start, @window_end) == %{
               ~D[2001-05-01] => card_bytes
             }

      assert Historian.pending_bytes_per_day("pages", @window_start, @window_end) == %{
               ~D[2001-05-01] => plain_bytes
             }

      # And the audit's raw counts, which must describe the same two
      # populations or every raw-vs-eligible gap is a false positive.
      assert HistorianAudit.raw_row_count("files", @window_start, @window_end) == 1
      assert HistorianAudit.raw_row_count("pages", @window_start, @window_end) == 1
    end

    test "the files corpus weighs the CARD, not the document it summarises",
         %{project: project, card: card} do
      # A 200 KB extracted document behind a card of a few hundred bytes —
      # the ratio the whole design turns on. If the byte signal ever
      # weighed `platform_file_texts.text`, this window would read as
      # ~50k tokens instead of ~100.
      file = Repo.one!(from(f in Files.File, where: f.card_file_key == ^card.file_key))
      {:ok, _} = Files.upsert_extracted_text(file.id, String.duplicate("d", 200_000))

      assert file.project_id == project.id

      bytes = Historian.pending_bytes_in_range("files", @window_start, @window_end)

      assert bytes == byte_size(card.content),
             "the files corpus must be weighted by card bytes (#{byte_size(card.content)}), " <>
               "got #{bytes} — a document-text weight would be ~200_000"

      assert bytes < 1_000
    end

    test "a soft-deleted file's card falls back to the pages corpus rather than vanishing",
         %{card: card} do
      file = Repo.one!(from(f in Files.File, where: f.card_file_key == ^card.file_key))
      {:ok, _} = Files.delete_file(%{id: Ecto.UUID.generate()}, file)

      files_items = ActivityDigest.corpus_items("files", @window_start, @window_end)
      pages_items = ActivityDigest.corpus_items("pages", @window_start, @window_end)

      assert files_items == []
      assert card.id in Enum.map(pages_items, & &1.id)

      # Still charged exactly once, just to the other corpus.
      assert HistorianAudit.raw_row_count("files", @window_start, @window_end) == 0
      assert HistorianAudit.raw_row_count("pages", @window_start, @window_end) == 2
    end

    test "the digest body renders cards under their own heading" do
      body =
        ActivityDigest.build_windowed(%{
          corpus: :files,
          window_start: @window_start,
          window_end: @window_end
        })

      assert body =~ "## File cards since"
      assert body =~ "### File cards"
      assert body =~ "[card]"
      assert body =~ "CARD-MARKER-A"
      refute body =~ "_No activity in this window._"
      refute body =~ "_(unknown corpus)_"
    end
  end

  # ── Fixtures ─────────────────────────────────────────────────────────────

  # A real card: a `platform_files` row, a wiki page at the cataloger's
  # own `card_file_key/1` path, and the backlink that joins them. Built
  # through `Files.mark_card_generated/2` rather than a direct insert, so
  # a change to how cards are recorded breaks this fixture loudly.
  defp seed_card_page(project, slug, content) do
    {:ok, file} =
      Files.create_file(%{
        project_id: project.id,
        org_id: fabrikam_org_id(),
        name: slug,
        original_filename: "#{slug}.pdf",
        content_type: "application/pdf",
        byte_size: 200_000,
        storage_key: "files/#{project.id}/#{slug}.pdf",
        content_hash: String.duplicate("e", 64)
      })

    {:ok, file} = Files.update_ingest_status(file, "ingested")

    card_key = "project/#{project.id}/page/files/#{slug}-#{String.slice(file.id, 0, 8)}.md"

    {:ok, page} =
      Wiki.upsert_page(card_key, %{
        content: content,
        org_id: fabrikam_org_id(),
        project_id: project.id
      })

    {:ok, _file} = Files.mark_card_generated(file, card_key)

    backdate(page)
  end

  defp seed_plain_page(file_key, content) do
    {:ok, page} = Wiki.upsert_page(file_key, %{content: content, org_id: fabrikam_org_id()})
    backdate(page)
  end

  # `updated_at` is stamped by the upsert, so a page inside a historical
  # window needs the same test-only escape hatch the other Historian
  # suites use.
  defp backdate(%WikiPage{} = page) do
    {1, _} =
      Repo.update_all(
        from(p in WikiPage, where: p.id == ^page.id),
        set: [updated_at: @row_at]
      )

    Repo.get!(WikiPage, page.id)
  end
end
