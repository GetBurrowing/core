defmodule Platform.Files.CardBackfillTest do
  @moduledoc false
  # `async: false`: the LLM provider is wired through application env and an
  # OS env var, both process-global.
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Files
  alias Platform.Files.CardBackfill
  alias Platform.Files.Cataloger
  alias Platform.Org.Wiki
  alias Platform.Org.WikiPage
  alias Platform.Tasks

  @api_key_env "CARD_BACKFILL_TEST_KEY"
  @stub_name :card_backfill_llm_test

  setup do
    {:ok, _} = Application.ensure_all_started(:req)

    previous_cfg = Application.get_env(:platform, :file_cards)

    # A stubbed-but-real provider, not `provider: :none`. Every "made no
    # LLM call" assertion below would otherwise pass vacuously — the call
    # would be short-circuited by config rather than by the boundary under
    # test.
    System.put_env(@api_key_env, "sk-card-backfill-test")

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

  describe "dry run is the default" do
    test "run/1 with no options spends nothing and writes nothing" do
      project = globex_project!("Backfill Default")
      a = ingested_file!(project, "Invoice.pdf", "An invoice for March.")
      b = ingested_file!(project, "Receipt.pdf", "A receipt for March.")

      stub_llm!(self(), "should never be reached\nSUPERSEDES: none")

      pages_before = Repo.aggregate(WikiPage, :count)

      report = CardBackfill.run(project_id: project.id)

      assert report.dry_run == true
      assert report.catalogable == 2
      assert report.already_catalogued == 0
      assert Enum.sort(report.candidates) == Enum.sort([a.id, b.id])
      assert report.catalogued == 0
      assert report.errors == []
      assert report.noops == []

      refute_received :llm_called
      assert Repo.aggregate(WikiPage, :count) == pages_before
      assert is_nil(Files.get_file(a.id).card_file_key)
      assert is_nil(Files.get_file(b.id).card_file_key)
    end

    test "the mix task with no arguments is a dry run" do
      # The task is where a human's fingers actually land, so the default
      # is asserted there and not only on the function it wraps.
      project = globex_project!("Backfill Mix Default")
      file = ingested_file!(project, "Statement.pdf", "A bank statement.")

      stub_llm!(self(), "should never be reached\nSUPERSEDES: none")

      pages_before = Repo.aggregate(WikiPage, :count)

      output = run_mix_task!(["--project-id", project.id])

      assert output =~ "DRY RUN — nothing written"
      assert output =~ "candidates: 1"
      assert output =~ "cards written: 0"
      assert output =~ "re-run with --write"

      refute_received :llm_called
      assert Repo.aggregate(WikiPage, :count) == pages_before
      assert is_nil(Files.get_file(file.id).card_file_key)
    end

    test "an unrecognised option aborts instead of silently widening the run" do
      # `--write --projct-id <uuid>` parses as "write, no scope" under a
      # lenient parser: one typo turns a one-project run into the whole
      # corpus. Refusing is the only safe reading.
      assert_raise Mix.Error, ~r/unrecognised arguments/, fn ->
        Mix.Tasks.Platform.BackfillFileCards.run(["--projct-id", "abc"])
      end
    end

    test "--dry-run beats --write when both are passed" do
      project = globex_project!("Backfill Ambiguous")
      file = ingested_file!(project, "Ambiguous.pdf", "Text.")

      stub_llm!(self(), "should never be reached\nSUPERSEDES: none")

      output = run_mix_task!(["--project-id", project.id, "--write", "--dry-run"])

      assert output =~ "DRY RUN — nothing written"
      refute_received :llm_called
      assert is_nil(Files.get_file(file.id).card_file_key)
    end
  end

  describe "enumeration goes through the eligibility seam, exclusively" do
    test "a human_only file is never a candidate and is never catalogued" do
      # ANTI-VACUITY TARGET. Replace `Files.list_catalogable_files/1` in
      # `card_backfill.ex` with a raw `Repo.all(File)` and this test must
      # fail. It is the only test in the suite that pins the backfill's
      # *enumeration*: `Cataloger.catalog_file/2` re-checks eligibility
      # too, so a "no LLM call" assertion alone would survive the mutation
      # on the cataloger's coattails and prove nothing about this module.
      #
      # The row is deliberately impossible-looking — human_only AND
      # ingested AND holding extracted text — because that is the shape
      # that would make a hand-rolled query walk a document whose bytes
      # are not allowed to leave the building into a third-party LLM.
      project = globex_project!("Backfill HumanOnly")
      ordinary = ingested_file!(project, "Public.pdf", "A public document.")

      secret =
        ingested_file!(project, "Payroll.pdf", "Salaries, by name.", intent: "human_only")

      stub_llm!(self(), "A public document.\nSUPERSEDES: none")

      census = CardBackfill.run(project_id: project.id)

      assert census.catalogable == 1,
             "the seam returned the human_only row to the backfill's census"

      assert census.candidates == [ordinary.id]
      refute secret.id in census.candidates

      # And the same through a real write run: the human_only row must not
      # appear in ANY bucket, because it must never have been enumerated.
      report = CardBackfill.run(project_id: project.id, dry_run: false)

      assert report.catalogued == 1
      assert report.errors == [], "a human_only row reached the cataloger and was refused there"
      assert report.noops == []

      assert is_nil(Files.get_file(secret.id).card_file_key)
      assert is_nil(Wiki.get_page(Cataloger.card_file_key(secret)))
      refute is_nil(Files.get_file(ordinary.id).card_file_key)
    end

    test "a soft-deleted file is never a candidate" do
      project = globex_project!("Backfill Deleted")
      keep = ingested_file!(project, "Keep.pdf", "Kept.")
      gone = ingested_file!(project, "Gone.pdf", "Deleted.")

      {:ok, _} = Files.delete_file(%{id: Ecto.UUID.generate(), type: "agent"}, gone)

      report = CardBackfill.run(project_id: project.id)

      assert report.candidates == [keep.id]
    end

    test "a file that never finished ingesting is never a candidate" do
      project = globex_project!("Backfill Pending")
      done = ingested_file!(project, "Done.pdf", "Ingested.")
      _pending = pending_file!(project, "Pending.pdf")

      report = CardBackfill.run(project_id: project.id)

      assert report.candidates == [done.id]
    end
  end

  describe "writing" do
    test "dry_run: false catalogs the candidates and is idempotent on a second run" do
      project = globex_project!("Backfill Write")
      a = ingested_file!(project, "One.pdf", "Document one.")
      b = ingested_file!(project, "Two.pdf", "Document two.")

      stub_llm!(self(), "A document.\nSUPERSEDES: none")

      first = CardBackfill.run(project_id: project.id, dry_run: false)

      assert first.dry_run == false
      assert first.catalogued == 2
      assert first.errors == []

      for file <- [a, b] do
        reloaded = Files.get_file(file.id)
        refute is_nil(reloaded.card_file_key)
        assert %WikiPage{} = Wiki.get_page(reloaded.card_file_key)
      end

      # Re-run: the retry strategy for this whole subsystem is "run the
      # backfill again", which is only safe if a carded row is inert.
      second = CardBackfill.run(project_id: project.id, dry_run: false)

      assert second.catalogable == 2
      assert second.already_catalogued == 2
      assert second.candidates == []
      assert second.catalogued == 0
    end

    test "a provider failure leaves card_file_key nil so the next run retries it" do
      project = globex_project!("Backfill Failure")
      file = ingested_file!(project, "Boom.pdf", "Text.")

      test_pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(test_pid, :llm_called)
        Plug.Conn.send_resp(conn, 500, ~s({"error":"upstream on fire"}))
      end)

      failed = CardBackfill.run(project_id: project.id, dry_run: false)

      assert_received :llm_called
      assert failed.catalogued == 0
      assert [{id, _reason}] = failed.errors
      assert id == file.id
      assert is_nil(Files.get_file(file.id).card_file_key)

      # There is no retry queue anywhere in this subsystem. The row being a
      # candidate again IS the retry.
      stub_llm!(self(), "Recovered.\nSUPERSEDES: none")

      retried = CardBackfill.run(project_id: project.id, dry_run: false)

      assert retried.catalogued == 1
      refute is_nil(Files.get_file(file.id).card_file_key)
    end

    test "--limit trims the work list without lying about the census" do
      project = globex_project!("Backfill Limit")
      _a = ingested_file!(project, "A.pdf", "Document A.")
      _b = ingested_file!(project, "B.pdf", "Document B.")
      _c = ingested_file!(project, "C.pdf", "Document C.")

      stub_llm!(self(), "A document.\nSUPERSEDES: none")

      report = CardBackfill.run(project_id: project.id, dry_run: false, limit: 1)

      assert report.catalogable == 3, "the census must count what exists, not what was worked"
      assert length(report.candidates) == 1
      assert report.catalogued == 1
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp run_mix_task!(args) do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)

    Mix.Tasks.Platform.BackfillFileCards.run(args)

    drain_mix_output()
  end

  defp drain_mix_output(acc \\ "") do
    receive do
      {:mix_shell, :info, [line]} -> drain_mix_output(acc <> line <> "\n")
    after
      0 -> acc
    end
  end

  defp globex_project!(name) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "#{name} #{System.unique_integer([:positive])}",
        org_id: tenant_org_id("globex")
      })

    project
  end

  defp file_attrs(project, filename) do
    %{
      project_id: project.id,
      original_filename: filename,
      name: filename,
      content_type: "application/pdf",
      byte_size: 1024,
      storage_key: "files/#{project.id}/#{System.unique_integer([:positive])}/#{filename}",
      content_hash:
        :crypto.hash(:sha256, "#{filename}#{System.unique_integer([:positive])}")
        |> Base.encode16(case: :lower)
    }
  end

  defp ingested_file!(project, filename, text, opts \\ []) do
    attrs =
      case Keyword.get(opts, :intent) do
        nil -> file_attrs(project, filename)
        intent -> Map.put(file_attrs(project, filename), :ingest_intent, intent)
      end

    {:ok, file} = Files.create_file(attrs)
    {:ok, file} = Files.update_ingest_status(file, "ingested")
    {:ok, _} = Files.upsert_extracted_text(file.id, text, nil)

    file
  end

  defp pending_file!(project, filename) do
    {:ok, file} = Files.create_file(file_attrs(project, filename))
    file
  end

  defp stub_llm!(test_pid, completion) do
    Req.Test.stub(@stub_name, fn conn ->
      send(test_pid, :llm_called)

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
