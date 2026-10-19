defmodule Platform.Files.CatalogEmitterTest do
  @moduledoc false
  # `async: false`: the LLM provider is wired through application env and
  # an OS env var (both process-global), and the emitter is a separate
  # process that needs the shared sandbox connection — which `DataCase`
  # only sets up on the non-async branch.
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Files
  alias Platform.Files.CatalogEmitter
  alias Platform.Files.Ingester
  alias Platform.Org.Wiki
  alias Platform.Tasks

  @api_key_env "CATALOG_EMITTER_TEST_KEY"
  @stub_name :catalog_emitter_llm_test
  @stop_event [:platform, :files, :ingested, :stop]

  setup do
    {:ok, _} = Application.ensure_all_started(:req)

    previous_cfg = Application.get_env(:platform, :file_cards)

    # A stubbed-but-real provider rather than `provider: :none`. Every
    # "made no LLM call" assertion below would otherwise pass vacuously:
    # the call would be short-circuited by config instead of by the
    # boundary under test.
    System.put_env(@api_key_env, "sk-catalog-emitter-test")

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

    # Registers the stub key with this process as its owner BEFORE any test
    # body runs. `Req.Test.allow/3` resolves against an existing owner, so
    # without a stub already in place the allowance in `start_emitter!/1`
    # has nothing to attach to and every cross-process call dies with
    # "cannot find mock/stub" — a failure that looks exactly like the
    # eligibility boundary refusing to spend money, which is the one
    # confusion this suite cannot afford. Tests overwrite it.
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.send_resp(conn, 500, ~s({"error":"no stub configured for this test"}))
    end)

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

  describe "wiring — the emitter is attached to the event the ingester really emits" do
    test "a real Ingester.run/1 reaches the emitter, with no hand-built event" do
      # The point of driving the REAL ingester: a test that only ever
      # calls `:telemetry.execute/3` with a hand-typed event name and a
      # hand-typed metadata map proves the emitter agrees with the test,
      # not that it agrees with `Platform.Files.Ingester`. The self-dedup
      # branch (`prior_id == file.id`) is the one path through `run/1`
      # that emits a genuine `:stop` without an extractor, a memory
      # provider or a supervisor hop.
      emitter = start_emitter!()

      project = globex_project!("Emitter Wiring")
      file = ingested_file!(project, "Repeat.pdf", "Some text.")

      assert :ok = Ingester.run(file)

      :ok = CatalogEmitter.await_idle(emitter)

      stats = CatalogEmitter.stats(emitter)
      assert stats.seen == 1, "the emitter never saw the ingester's :stop event"

      # dedup=true on a file with no card and no carded origin is a
      # deliberate no-op, not an error — see `Cataloger.catalog_dedup/3`.
      assert stats.noop == 1
      assert stats.catalogued == 0
      refute_received :llm_called
    end

    test "the handler is attached on boot and detached when the process stops" do
      emitter = start_emitter!()

      assert Enum.any?(:telemetry.list_handlers(@stop_event), &(&1.config[:server] == emitter))

      :ok = stop_supervised(emitter)

      refute Enum.any?(:telemetry.list_handlers(@stop_event), &(&1.config[:server] == emitter))
    end
  end

  describe "cataloging on ingest" do
    test "an eligible file gets a card written from the ingest event" do
      emitter = start_emitter!()

      project = globex_project!("Emitter Catalog")
      file = ingested_file!(project, "Statement.pdf", "A bank statement for June.")

      stub_llm!(self(), "A June bank statement.\nSUPERSEDES: none")

      emit_stop!(file)
      :ok = CatalogEmitter.await_idle(emitter)

      assert_received :llm_called

      reloaded = Files.get_file(file.id)
      refute is_nil(reloaded.card_file_key)
      assert %{} = Wiki.get_page(reloaded.card_file_key)

      assert CatalogEmitter.stats(emitter).catalogued == 1
    end
  end

  describe "eligibility is re-derived through the seam, not trusted from the event" do
    test "a human_only file named by a :stop event is never loaded, never summarized" do
      # THE boundary test for this stage. Telemetry is a public bus:
      # anything in the VM can execute this event with any metadata it
      # likes, and today's ingester short-circuit (no :stop ever fires
      # for human_only) is not a property the handler can lean on.
      #
      # The row below is deliberately impossible-looking — human_only AND
      # ingested AND holding extracted text — because that is exactly the
      # shape that would make a trusting handler spend money on a
      # document whose bytes are not allowed to leave the building.
      emitter = start_emitter!()

      project = globex_project!("Emitter HumanOnly")
      file = ingested_file!(project, "Payroll.pdf", "Salaries, by name.", intent: "human_only")

      stub_llm!(self(), "should never be reached\nSUPERSEDES: none")

      emit_stop!(file)
      :ok = CatalogEmitter.await_idle(emitter)

      refute_received :llm_called

      assert is_nil(Files.get_file(file.id).card_file_key)
      assert is_nil(Wiki.get_page(Platform.Files.Cataloger.card_file_key(file)))

      stats = CatalogEmitter.stats(emitter)
      assert stats.seen == 1
      assert stats.ineligible == 1
      assert stats.catalogued == 0
    end

    test "a soft-deleted file named by a :stop event is refused the same way" do
      emitter = start_emitter!()

      project = globex_project!("Emitter Deleted")
      file = ingested_file!(project, "Old.pdf", "Superseded content.")
      {:ok, _} = Files.delete_file(%{id: Ecto.UUID.generate(), type: "agent"}, file)

      stub_llm!(self(), "should never be reached\nSUPERSEDES: none")

      emit_stop!(file)
      :ok = CatalogEmitter.await_idle(emitter)

      refute_received :llm_called
      assert CatalogEmitter.stats(emitter).ineligible == 1
    end

    test "an event whose project_id points somewhere else catalogs nothing" do
      # The seam is queried by the metadata's project_id, so a file_id
      # that is genuinely catalogable in project A cannot be catalogued
      # by an event claiming project B.
      emitter = start_emitter!()

      project = globex_project!("Emitter Scope A")
      other = globex_project!("Emitter Scope B")
      file = ingested_file!(project, "Scoped.pdf", "Text.")

      stub_llm!(self(), "should never be reached\nSUPERSEDES: none")

      emit_stop!(file, project_id: other.id)
      :ok = CatalogEmitter.await_idle(emitter)

      refute_received :llm_called
      assert is_nil(Files.get_file(file.id).card_file_key)
      assert CatalogEmitter.stats(emitter).ineligible == 1
    end
  end

  describe "burst concurrency" do
    test "a burst of ingests never puts two card passes in flight at once" do
      # The constraint this stage exists to satisfy. The live corpus shows
      # twelve files finishing inside 0.2s; the ingester spawns one Task
      # per file, so nothing upstream serialises them.
      #
      # The stub blocks INSIDE the provider call, in whatever process is
      # making it. If a second pass could start, its request would arrive
      # while the first is parked and this test would see a second
      # `:llm_called`.
      emitter = start_emitter!()

      project = globex_project!("Emitter Burst")

      files =
        for n <- 1..3, do: ingested_file!(project, "Burst#{n}.pdf", "Document number #{n}.")

      blocking_stub!(self(), "A document.\nSUPERSEDES: none")

      Enum.each(files, &emit_stop!/1)

      assert_receive {:llm_called, first_pid}, 5_000

      refute_receive {:llm_called, _},
                     300,
                     "a second card pass started while the first was parked"

      send(first_pid, :release)

      assert_receive {:llm_called, second_pid}, 5_000
      refute_receive {:llm_called, _}, 300
      send(second_pid, :release)

      assert_receive {:llm_called, third_pid}, 5_000
      send(third_pid, :release)

      :ok = CatalogEmitter.await_idle(emitter)

      stats = CatalogEmitter.stats(emitter)
      assert stats.seen == 3
      assert stats.catalogued == 3
    end

    test "backlog past :max_queue is dropped for the backfill, not queued forever" do
      # Overflow must not turn into an unbounded mailbox. A dropped card
      # is not a lost one: `card_file_key` stays nil, which is exactly
      # what `mix platform.backfill_file_cards` enumerates.
      emitter = start_emitter!(max_queue: 1)

      project = globex_project!("Emitter Overflow")
      files = for n <- 1..4, do: ingested_file!(project, "Flood#{n}.pdf", "Document #{n}.")

      blocking_stub!(self(), "A document.\nSUPERSEDES: none")

      Enum.each(files, &emit_stop!/1)

      assert_receive {:llm_called, first_pid}, 5_000
      send(first_pid, :release)

      release_until_idle(emitter)

      stats = CatalogEmitter.stats(emitter)

      assert stats.dropped >= 1,
             "four events queued behind a parked pass with max_queue: 1 dropped nothing"

      assert stats.seen == 4

      assert stats.seen ==
               stats.catalogued + stats.noop + stats.ineligible + stats.errors + stats.dropped,
             "every event must land in exactly one bucket — a missing one is a silent loss"
    end
  end

  describe "failure isolation" do
    test "a provider failure leaves card_file_key nil and the emitter alive" do
      # The retry strategy for this whole subsystem is the backfill. A
      # failed pass must therefore be indistinguishable from a
      # never-attempted one at the row level, and must not take the
      # emitter (or the cards queued behind it) down with it.
      emitter = start_emitter!()

      project = globex_project!("Emitter Failure")
      boom = ingested_file!(project, "Boom.pdf", "Text one.")
      ok = ingested_file!(project, "Fine.pdf", "Text two.")

      test_pid = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(test_pid, :llm_called)
        Plug.Conn.send_resp(conn, 500, ~s({"error":"upstream on fire"}))
      end)

      emit_stop!(boom)
      :ok = CatalogEmitter.await_idle(emitter)

      assert is_nil(Files.get_file(boom.id).card_file_key)
      assert Process.alive?(Process.whereis(emitter))
      assert CatalogEmitter.stats(emitter).errors == 1

      stub_llm!(self(), "A fine document.\nSUPERSEDES: none")

      emit_stop!(ok)
      :ok = CatalogEmitter.await_idle(emitter)

      refute is_nil(Files.get_file(ok.id).card_file_key)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # The child spec is re-`id`'d to the instance name so `stop_supervised/1`
  # has something to name: `{CatalogEmitter, opts}` would register under the
  # MODULE, and the detach test needs to stop one specific instance.
  #
  # `Req.Test.allow/3` is the other half. The stub is owned by the test
  # process and the card pass runs inside the emitter's own process, so
  # without the allowance every pass raises "cannot find mock/stub" — which
  # reads exactly like the boundary refusing to call the LLM. That failure
  # mode is why the allowance is here rather than per-test.
  defp start_emitter!(opts \\ []) do
    name = :"catalog_emitter_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        Supervisor.child_spec({CatalogEmitter, Keyword.put(opts, :name, name)}, id: name)
      )

    Req.Test.allow(@stub_name, self(), pid)

    name
  end

  defp emit_stop!(file, overrides \\ []) do
    meta =
      %{
        file_id: file.id,
        project_id: file.project_id,
        byte_size: file.byte_size,
        dedup: false,
        chunk_count: 1
      }
      |> Map.merge(Map.new(overrides))

    :telemetry.execute(@stop_event, %{duration: 1_000, extracted_chars: 100}, meta)
  end

  # Drains whatever is still queued, releasing each parked pass as it
  # announces itself. `await_idle/2` cannot be called first: the server is
  # single-threaded, so the call would sit behind a pass waiting on a
  # release this process has not sent yet.
  defp release_until_idle(emitter) do
    receive do
      {:llm_called, pid} ->
        send(pid, :release)
        release_until_idle(emitter)
    after
      500 -> :ok = CatalogEmitter.await_idle(emitter)
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

  defp ingested_file!(project, filename, text, opts \\ []) do
    attrs = %{
      project_id: project.id,
      original_filename: filename,
      name: filename,
      content_type: "application/pdf",
      byte_size: 1024,
      storage_key: "files/#{project.id}/#{System.unique_integer([:positive])}/#{filename}",
      content_hash: :crypto.hash(:sha256, filename) |> Base.encode16(case: :lower)
    }

    attrs =
      case Keyword.get(opts, :intent) do
        nil -> attrs
        intent -> Map.put(attrs, :ingest_intent, intent)
      end

    {:ok, file} = Files.create_file(attrs)
    {:ok, file} = Files.update_ingest_status(file, "ingested")
    {:ok, _} = Files.upsert_extracted_text(file.id, text, nil)

    file
  end

  defp stub_llm!(test_pid, completion) do
    Req.Test.stub(@stub_name, fn conn ->
      send(test_pid, :llm_called)
      respond(conn, completion)
    end)
  end

  # Parks the calling process — which is the process making the card pass —
  # until the test releases it. The `receive` is selective, so the casts
  # already queued in the emitter's mailbox stay there untouched.
  defp blocking_stub!(test_pid, completion) do
    Req.Test.stub(@stub_name, fn conn ->
      send(test_pid, {:llm_called, self()})

      receive do
        :release -> :ok
      after
        10_000 -> :ok
      end

      respond(conn, completion)
    end)
  end

  defp respond(conn, completion) do
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
  end
end
