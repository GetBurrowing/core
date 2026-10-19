defmodule Platform.Files.CatalogerTest do
  @moduledoc false
  # `async: false`: every test here wires the LLM provider through
  # application env (`:file_cards`, `:anthropic_req_client`) and an OS
  # env var, all of which are process-global.
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Files
  alias Platform.Files.CardPrompt
  alias Platform.Files.Cataloger
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Tasks

  @api_key_env "FILE_CARDS_TEST_KEY"
  @stub_name :file_cards_llm_test

  setup do
    {:ok, _} = Application.ensure_all_started(:req)

    previous_cfg = Application.get_env(:platform, :file_cards)

    # A stubbed-but-real provider, not `provider: :none`. With `:none`
    # every "made no LLM call" assertion below would pass vacuously —
    # the call would be short-circuited by config rather than by the
    # logic under test. Wiring a real adapter at a Req.Test plug turns
    # "did the pass run?" into a message in this process's mailbox.
    System.put_env(@api_key_env, "sk-file-cards-test")

    Application.put_env(:platform, :file_cards, %{
      provider: :anthropic,
      model: "claude-card-test",
      api_key_env: @api_key_env,
      max_tokens: 700,
      temperature: 0.2
    })

    Application.put_env(
      :platform,
      :anthropic_req_client,
      Req.new(plug: {Req.Test, @stub_name})
    )

    on_exit(fn ->
      Application.delete_env(:platform, :anthropic_req_client)
      System.delete_env(@api_key_env)

      if previous_cfg do
        Application.put_env(:platform, :file_cards, previous_cfg)
      else
        Application.delete_env(:platform, :file_cards)
      end
    end)

    :ok
  end

  describe "tenancy — a card lands under its own project, not the root org" do
    test "the written row carries the project's real org_id and a non-nil project_id" do
      # THE test for this stage's blocker. `Wiki.upsert_page/3` used to
      # read only :content and :updated_by, so a page written at an Globex
      # project path was stored as an Acme row with a nil project_id and
      # `update_changeset/2` could never repair it.
      #
      # Note what is NOT asserted here on its own: that a page exists at
      # the right file_key. That assertion passes against the broken
      # code — the path was always right; the row was always wrong.
      project = globex_project!("Tenancy Card")
      file = ingested_file!(project, "Contract.pdf", "A signed services contract.")

      stub_llm!(self(), "A services contract between two parties.\nSUPERSEDES: none")

      assert {:ok, %WikiPage{} = page} = Cataloger.catalog_file(file)

      row = Repo.get!(WikiPage, page.id)

      assert row.org_id == tenant_org_id("globex"),
             "the card row's org_id must be the project's org, not whatever " <>
               "`maybe_default_org_id/1` fell back to"

      refute row.org_id == acme_org_id(),
             "the card landed in the root Acme org — the path says Globex and the row says Acme"

      assert row.project_id == project.id
      refute is_nil(row.project_id)
    end

    test "a card written at a project path is repairable — the update path carries tenancy too" do
      # `update_changeset/2` cast neither column before this stage, which
      # is what made the Acme default permanent rather than merely wrong.
      # Simulate the legacy row, then catalog over it.
      project = globex_project!("Repair Card")
      file = ingested_file!(project, "Brief.pdf", "A project brief.")

      key = Cataloger.card_file_key(file)

      {:ok, legacy} = Wiki.upsert_page(key, %{content: "legacy body"})
      assert legacy.org_id == acme_org_id(), "precondition: the legacy shape is an Acme row"
      assert is_nil(legacy.project_id)

      stub_llm!(self(), "A brief.\nSUPERSEDES: none")

      assert {:ok, _page} = Cataloger.catalog_file(file)

      row = Repo.get_by!(WikiPage, file_key: key)
      assert row.org_id == tenant_org_id("globex")
      assert row.project_id == project.id
      assert row.version == 2, "precondition: this went through the UPDATE path, not an insert"
    end

    test "refuses to write at all when the project cannot supply an org" do
      # Falling through to `maybe_default_org_id/1` is the bug this
      # stage exists to kill; refusing is the only other honest option.
      #
      # Driven from an in-memory struct on purpose. `platform_files`
      # FK-restricts `project_id` and `projects` requires `org_id`, so
      # neither shape can be persisted — the guard is defensive against
      # a struct built or mutated in application code, and that is the
      # only level at which it is reachable. Persisting it raises
      # `Ecto.ConstraintError` before the cataloger is ever called.
      orphan = %Platform.Files.File{
        id: Platform.Types.UUIDv7.generate(),
        project_id: Ecto.UUID.generate(),
        original_filename: "Orphan.pdf",
        ingest_status: "ingested",
        ingest_intent: "attempt"
      }

      assert {:error, :no_project} = Cataloger.catalog_file(orphan)
      refute_received :llm_called
    end
  end

  describe "self-gating — the writer constrains its own paths" do
    test "refuses a file_key outside the project's card prefix" do
      # Nothing upstream enforces this: `upsert_page/3` performs no
      # authorization and never consults `Wiki.Routing`. The
      # `:historian_required` gate lives at the MCP tool surface, which
      # a server-side emitter never crosses.
      project = globex_project!("Gate Card")

      # A positive trace rather than "the page is absent": `upsert_page/3`
      # emits an index event on every write, so no event means no write.
      # Asserting absence would be weaker here anyway — this path is
      # seeded in some environments, so "absent" is not a state the
      # refusal produces.
      Phoenix.PubSub.subscribe(Platform.PubSub, Wiki.index_topic())

      assert {:error, {:refused_path, "org/page/identity.md"}} =
               Cataloger.write_card(
                 "org/page/identity.md",
                 "clobbered",
                 tenant_org_id("globex"),
                 project.id
               )

      refute_receive {:wiki_page_written, _}, 200

      refute match?(%{content: "clobbered"}, Wiki.get_page("org/page/identity.md"))
    end

    test "refuses a well-formed card path belonging to a DIFFERENT project" do
      # The shape a mixed-up file_id or a stale struct produces. The path
      # is a perfectly valid card path — just not this project's.
      mine = globex_project!("Gate Mine")
      theirs = globex_project!("Gate Theirs")

      foreign_key = "project/#{theirs.id}/page/files/something-abcd1234.md"

      Phoenix.PubSub.subscribe(Platform.PubSub, Wiki.index_topic())

      assert {:error, {:refused_path, ^foreign_key}} =
               Cataloger.write_card(foreign_key, "body", tenant_org_id("globex"), mine.id)

      refute_receive {:wiki_page_written, _}, 200
      assert is_nil(Wiki.get_page(foreign_key))
    end

    test "refuses a traversal dressed up as a slug" do
      project = globex_project!("Gate Traversal")
      key = "project/#{project.id}/page/files/../../../org/page/identity.md"

      assert {:error, {:refused_path, ^key}} =
               Cataloger.write_card(key, "body", tenant_org_id("globex"), project.id)
    end

    test "accepts the card path it builds for itself" do
      # Positive control. Without this, the gate could refuse everything
      # and all three tests above would still pass.
      project = globex_project!("Gate Positive")
      file = ingested_file!(project, "Ok.pdf", "text")

      assert Cataloger.card_path?(Cataloger.card_file_key(file), project.id)
    end
  end

  describe "the LLM pass and supersession resolution" do
    test "records a supersession claim that resolves to a real sibling" do
      project = globex_project!("Supersession Resolves")
      original = ingested_file!(project, "Acme x Globex (Order Form).pdf", "Order form, June.")

      revision =
        ingested_file!(project, "Acme x Globex (Order Form) v1.3.pdf", "Order form, July.")

      stub_llm!(
        self(),
        "A revised order form.\nSUPERSEDES: Acme x Globex (Order Form).pdf"
      )

      assert {:ok, page} = Cataloger.catalog_file(revision)

      assert page.frontmatter["supersedes_file_id"] == original.id
      assert page.frontmatter["supersedes_filename"] == "Acme x Globex (Order Form).pdf"

      assert page.frontmatter["supersession_ruling"] == "unruled",
             "the claim is recorded immediately as visible metadata and never blocks the card"

      assert page.content =~ "Supersedes: Acme x Globex (Order Form).pdf"
    end

    test "DROPS a claim naming a document that is not in the sibling set" do
      # A single-document pass cannot know supersession; asked in
      # isolation it guesses from the filename. An unresolvable claim
      # written into a card is a dangling reference in the one artifact
      # whose entire value is being trustworthy. A dropped claim is not.
      project = globex_project!("Supersession Drops")
      _sibling = ingested_file!(project, "Acme x Globex (Order Form).pdf", "Order form, June.")
      subject = ingested_file!(project, "Statement of Work.pdf", "An SOW.")

      stub_llm!(
        self(),
        "A statement of work.\nSUPERSEDES: Acme x Globex (Master Services Agreement) v2.pdf"
      )

      assert {:ok, page} = Cataloger.catalog_file(subject)

      refute Map.has_key?(page.frontmatter, "supersedes_file_id")
      refute Map.has_key?(page.frontmatter, "supersedes_filename")
      refute page.content =~ "Supersedes:"
      refute page.content =~ "Master Services Agreement"

      assert page.content =~ "A statement of work.",
             "dropping the claim must not drop the card — it still auto-publishes"
    end

    test "the sibling roster gives the model filenames and dates, and no ids" do
      # ~20 tokens a row is the budget the design settled on. A UUID
      # costs more than the filename and date together, and matching on
      # the string the model was SHOWN is stricter than matching on one
      # it was asked to copy.
      project = globex_project!("Roster Shape")
      sibling = ingested_file!(project, "Acme x Globex (Order Form).pdf", "June.")
      subject = ingested_file!(project, "Statement of Work.pdf", "An SOW.")

      stub_llm!(self(), "An SOW.\nSUPERSEDES: none")

      assert {:ok, _page} = Cataloger.catalog_file(subject)

      assert_received {:llm_body, body}
      prompt = Enum.map_join(body["messages"], "\n", & &1["content"])

      assert prompt =~ "Acme x Globex (Order Form).pdf"
      assert prompt =~ Date.to_iso8601(DateTime.to_date(sibling.inserted_at))

      refute prompt =~ sibling.id,
             "sibling ids must not be spent on the roster"
    end

    test "stamps card_file_key and card_generated_at back onto the row" do
      project = globex_project!("Backlink")
      file = ingested_file!(project, "Notes.md", "Some notes.")

      stub_llm!(self(), "Notes.\nSUPERSEDES: none")

      assert {:ok, page} = Cataloger.catalog_file(file)

      reloaded = Files.get_file(file.id)
      assert reloaded.card_file_key == page.file_key
      assert reloaded.card_file_key == Cataloger.card_file_key(file)
      refute is_nil(reloaded.card_generated_at)
    end

    test "a human_only file never reaches the LLM" do
      # The seam is a disclosure boundary. This module re-checks it
      # rather than trusting its caller, because a boundary that trusts
      # its input is not one.
      project = globex_project!("Withheld")
      file = ingested_file!(project, "atlas_prompts.mjs", "SECRET-MARKER")
      {:ok, withheld} = Files.set_ingest_intent(file, "human_only")

      stub_llm!(self(), "should never be produced\nSUPERSEDES: none")

      assert {:error, :not_catalogable} = Cataloger.catalog_file(withheld)
      refute_received :llm_called
      assert is_nil(Wiki.get_page(Cataloger.card_file_key(withheld)))
    end
  end

  describe "the dedup path — copy the body, spend nothing" do
    test "a deduped file gets its OWN card, copied from the origin, with zero LLM calls" do
      # Structural, not an optimisation: the ingester's dedup clause
      # copies chunk rows and flips status to "ingested" but never
      # calls `upsert_extracted_text/3`. There is no
      # `platform_file_texts` row to summarize even if the tokens were
      # free — which is why the deduped file below is created WITHOUT
      # one.
      allow_hash_twins!()

      project = globex_project!("Dedup Copy")
      hash = content_hash("shared-bytes")

      origin = ingested_file!(project, "Order Form.pdf", "The order form text.", hash: hash)
      stub_llm!(self(), "The origin card body.\nSUPERSEDES: none")
      assert {:ok, origin_page} = Cataloger.catalog_file(origin)
      assert_received :llm_called

      duplicate = ingested_file!(project, "Order Form (copy).pdf", nil, hash: hash)

      assert {:ok, dup_page} = Cataloger.catalog_file(reload(duplicate), dedup: true)

      refute_received :llm_called,
                      "the dedup path called the LLM — there is no extracted text to summarize"

      assert dup_page.file_key == Cataloger.card_file_key(duplicate)
      refute dup_page.file_key == origin_page.file_key, "the copy must land at its OWN slug"

      assert dup_page.content =~ "The origin card body."
      assert dup_page.frontmatter["file_id"] == duplicate.id
      assert dup_page.frontmatter["copied_from_file_id"] == origin.id

      assert dup_page.org_id == tenant_org_id("globex")
      assert dup_page.project_id == project.id

      assert reload(duplicate).card_file_key == dup_page.file_key
    end

    test "SELF-dedup is a no-op — no rewrite, no new timestamp, no LLM call, no write event" do
      # The ingester's `prior_id == file.id` clause (re-running ingest
      # after a successful run) carries `dedup: true` and
      # `chunk_count: 0` exactly like a real dedup. Conflating the two
      # rewrites a card that has no new information behind it.
      project = globex_project!("Dedup Self")
      file = ingested_file!(project, "Stable.pdf", "Stable text.")

      stub_llm!(self(), "The only card body.\nSUPERSEDES: none")
      assert {:ok, page} = Cataloger.catalog_file(file)
      assert_received :llm_called

      before = reload(file)

      # A positive trace, not "the row still reads X": the wiki emits an
      # index event on EVERY write, so an event that never arrives is
      # proof no write happened. "The content is unchanged" would also
      # hold if the card were rewritten with identical text.
      Phoenix.PubSub.subscribe(Platform.PubSub, Wiki.index_topic())

      assert {:ok, :noop, :already_catalogued} = Cataloger.catalog_file(before, dedup: true)

      refute_received :llm_called
      refute_receive {:wiki_page_written, _}, 200

      after_row = reload(file)
      assert after_row.card_generated_at == before.card_generated_at
      assert after_row.card_file_key == before.card_file_key

      assert Repo.get!(WikiPage, page.id).version == page.version,
             "the card was rewritten — the version counter moved"
    end

    test "self-dedup stays a no-op even when a hash-twin with a card exists" do
      # The conflation trap. Re-running ingest on the ORIGINAL while a
      # duplicate sits alongside it looks exactly like a copy-dedup if
      # you resolve the origin by content hash alone.
      allow_hash_twins!()

      project = globex_project!("Dedup Twin")
      hash = content_hash("twin-bytes")

      origin = ingested_file!(project, "Twin A.pdf", "Twin text.", hash: hash)
      stub_llm!(self(), "Origin body.\nSUPERSEDES: none")
      assert {:ok, origin_page} = Cataloger.catalog_file(origin)

      twin = ingested_file!(project, "Twin B.pdf", nil, hash: hash)
      assert {:ok, _} = Cataloger.catalog_file(reload(twin), dedup: true)

      Phoenix.PubSub.subscribe(Platform.PubSub, Wiki.index_topic())

      assert {:ok, :noop, :already_catalogued} =
               Cataloger.catalog_file(reload(origin), dedup: true)

      refute_receive {:wiki_page_written, _}, 200
      assert Repo.get!(WikiPage, origin_page.id).version == origin_page.version
    end

    test "a dedup whose origin has no card yet writes nothing and leaves it to the backfill" do
      allow_hash_twins!()

      project = globex_project!("Dedup No Origin")
      hash = content_hash("uncatalogued-bytes")

      _origin = ingested_file!(project, "Uncatalogued.pdf", "text", hash: hash)
      duplicate = ingested_file!(project, "Uncatalogued (copy).pdf", nil, hash: hash)

      assert {:ok, :noop, :no_origin_card} = Cataloger.catalog_file(duplicate, dedup: true)

      refute_received :llm_called
      assert is_nil(reload(duplicate).card_file_key)
    end
  end

  describe "CardPrompt response parsing" do
    test "strips the marker line out of the prose" do
      assert {"Body text.", "Some File.pdf"} =
               CardPrompt.split_response("Body text.\nSUPERSEDES: Some File.pdf")
    end

    test "treats none-tokens as no claim" do
      for token <- ["none", "None", "N/A", "-", ""] do
        assert {"Body.", nil} = CardPrompt.split_response("Body.\nSUPERSEDES: #{token}")
      end
    end

    test "an omitted marker line is no claim, and the prose survives intact" do
      assert {"Body.", nil} = CardPrompt.split_response("Body.")
    end

    test "resolution is exact-ish, not fuzzy" do
      siblings = [%{id: "a", filename: "Order Form.pdf", date: "2026-06-25"}]

      assert {:ok, %{id: "a"}} = CardPrompt.resolve_supersession("Order Form.pdf", siblings)
      assert {:ok, %{id: "a"}} = CardPrompt.resolve_supersession("\"order form.pdf\"", siblings)
      assert {:error, :unresolvable} = CardPrompt.resolve_supersession("Order Form", siblings)
      assert {:error, :no_claim} = CardPrompt.resolve_supersession(nil, siblings)
    end

    test "an ambiguous name resolves to nothing rather than to a guess" do
      siblings = [
        %{id: "a", filename: "Order Form.pdf", date: "2026-06-25"},
        %{id: "b", filename: "Order Form.pdf", date: "2026-07-10"}
      ]

      assert {:error, :ambiguous} = CardPrompt.resolve_supersession("Order Form.pdf", siblings)
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp globex_project!(name) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "#{name} #{System.unique_integer([:positive])}",
        org_id: tenant_org_id("globex")
      })

    project
  end

  # An ingested file with (optionally) a `platform_file_texts` row.
  # `text: nil` produces the deduped shape: status "ingested", no
  # extracted text — exactly what `Ingester.do_run/3`'s dedup clause
  # leaves behind.
  defp ingested_file!(project, filename, text, opts \\ []) do
    hash = Keyword.get(opts, :hash, content_hash(filename))

    {:ok, file} =
      Files.create_file(%{
        project_id: project.id,
        original_filename: filename,
        name: filename,
        content_type: "application/pdf",
        byte_size: 1024,
        storage_key: "files/#{project.id}/#{System.unique_integer([:positive])}/#{filename}",
        content_hash: hash
      })

    {:ok, file} = Files.update_ingest_status(file, "ingested")

    if is_binary(text), do: {:ok, _} = Files.upsert_extracted_text(file.id, text, nil)

    file
  end

  defp reload(file), do: Files.get_file(file.id)

  # FINDING, recorded here because the tests that need it are the proof.
  #
  # `platform_files` carries UNIQUE `(content_hash, project_id)`
  # (`20260619025255_create_platform_files.exs:70`, still the only
  # migration that touches it). `Ingester.do_run/3` resolves dedup with
  # `Files.find_ingested_sibling/2`, which is project-scoped — so within
  # one project the ONLY row that lookup can ever return for a given
  # hash is the file itself. The copy-dedup clause (`ingester.ex:177-188`,
  # `prior_id != file.id`) is therefore unreachable in production: two
  # rows in one project cannot share a hash, and the index is not
  # partial, so a soft-deleted original blocks the re-upload too. The
  # migration's own comment says as much: "the same bytes uploaded twice
  # to one project collapse to one row."
  #
  # The card writer still implements the copy, because the ingester
  # branch exists and the constraint is a decision that could be
  # revisited. Dropping the index inside the test's sandbox transaction
  # (it rolls back with everything else) is what makes that branch
  # reachable enough to pin. If this line ever stops being necessary,
  # the constraint changed and the finding is stale.
  defp allow_hash_twins! do
    Repo.query!("DROP INDEX platform_files_content_hash_project_id_index")
  end

  defp content_hash(seed),
    do: Base.encode16(:crypto.hash(:sha256, seed), case: :lower)

  # Answers 200 with an Anthropic-shaped body and reports every call to
  # the test process, so "no LLM call" is an empty mailbox rather than
  # an inference from state.
  defp stub_llm!(test_pid, completion) do
    Req.Test.stub(@stub_name, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(test_pid, :llm_called)
      send(test_pid, {:llm_body, Jason.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "id" => "msg_test",
          "model" => "claude-card-test",
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 100, "output_tokens" => 100},
          "content" => [%{"type" => "text", "text" => completion}]
        })
      )
    end)
  end
end
