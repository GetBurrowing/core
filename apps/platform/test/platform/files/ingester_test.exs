defmodule Platform.Files.IngesterTest do
  @moduledoc """
  Tests for the Stage 3 ingest pipeline.

  Rather than reach for Mox (the suite codebase isn't wired for it; the
  Memory tests use the same swap-`:provider`-out pattern), each test
  here installs a small in-process `Platform.Memory.Provider` impl that
  reports back to the test via `send/2`. This keeps the assertions tight
  (we see the exact entry that hit the provider) and lets us assert
  call counts via `refute_received`.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Files
  alias Platform.Files.Ingester
  alias Platform.Tasks

  # ── Capture providers ──────────────────────────────────────────────────

  defmodule CaptureProvider do
    @moduledoc false
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(entries, _config) do
      Enum.each(entries, fn entry ->
        case Process.get(:ingest_test_pid) do
          nil -> :ok
          pid -> send(pid, {:provider_ingest, entry})
        end
      end)

      {:ok, length(entries)}
    end

    @impl true
    def search(_q, _o, _c), do: {:ok, []}
    @impl true
    def delete(_ids, _c), do: {:ok, 0}
    @impl true
    def health(_c), do: :ok
  end

  defmodule BroadcastProvider do
    @moduledoc false
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(entries, _config) do
      # Broadcast to ALL test pids registered via :global so multiple
      # concurrent tests don't trip over each other — but in practice
      # the file ingester runs sync in this test module (async: false),
      # so we can lean on Process.get and a single global pid.
      pid = :persistent_term.get({__MODULE__, :pid}, nil)
      if pid, do: Enum.each(entries, &send(pid, {:provider_ingest, &1}))
      {:ok, length(entries)}
    end

    @impl true
    def search(_q, _o, _c), do: {:ok, []}
    @impl true
    def delete(_ids, _c), do: {:ok, 0}
    @impl true
    def health(_c), do: :ok
  end

  defmodule FailingProvider do
    @moduledoc false
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(_entries, _config), do: {:error, "connect timed out after 5000ms"}

    @impl true
    def search(_q, _o, _c), do: {:ok, []}
    @impl true
    def delete(_ids, _c), do: {:ok, 0}
    @impl true
    def health(_c), do: :ok
  end

  # ── Setup ──────────────────────────────────────────────────────────────

  setup do
    original = Application.get_env(:platform, :memory_service, [])
    Application.put_env(:platform, :memory_service, provider: BroadcastProvider)
    :persistent_term.put({BroadcastProvider, :pid}, self())

    on_exit(fn ->
      Application.put_env(:platform, :memory_service, original)
      :persistent_term.erase({BroadcastProvider, :pid})
    end)

    # Each test gets its own tmp dir for the local-disk attachment
    # adapter so the extractor's `local_path/1` resolves cleanly.
    root =
      Platform.TestTemp.path("platform-files-ingester-test")

    File.mkdir_p!(root)

    previous_root = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous_root,
        do: Application.put_env(:platform, :chat_attachments_root, previous_root),
        else: Application.delete_env(:platform, :chat_attachments_root)
    end)

    {:ok, project} = Tasks.create_project(%{name: "Ingester Test #{System.unique_integer()}"})

    {:ok, project: project, root: root}
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp create_text_file(project, root, body, opts \\ []) do
    filename = Keyword.get(opts, :filename, "ingester-fixture.txt")
    content_type = Keyword.get(opts, :content_type, "text/plain")
    hash = Keyword.get(opts, :content_hash, fake_hash(body, project.id))

    storage_key =
      Keyword.get(
        opts,
        :storage_key,
        "files/#{project.id}/#{Ecto.UUID.generate()}/#{filename}"
      )

    abs_path = Path.join(root, storage_key)
    File.mkdir_p!(Path.dirname(abs_path))
    File.write!(abs_path, body)

    {:ok, file} =
      Files.create_file(%{
        project_id: project.id,
        org_id: project.org_id,
        name: filename,
        original_filename: filename,
        content_type: content_type,
        byte_size: byte_size(body),
        storage_key: storage_key,
        content_hash: hash
      })

    file
  end

  defp fake_hash(body, project_id) do
    # Real SHA but salted with the project so two helper calls in
    # different projects don't accidentally collide.
    :crypto.hash(:sha256, project_id <> ":" <> body) |> Base.encode16(case: :lower)
  end

  defp attach_telemetry(events) do
    handler_id = "ingester-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, name, measurements, metadata})
      end,
      %{}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # ── Tests ──────────────────────────────────────────────────────────────

  describe "ingest_async/1 happy path" do
    test "calls the memory provider once with project_id + memory_type=document",
         %{project: project, root: root} do
      attach_telemetry([
        [:platform, :files, :ingested, :start],
        [:platform, :files, :ingested, :stop]
      ])

      file = create_text_file(project, root, "arctic photovoltaic resonance")

      :ok = Ingester.run(file)

      assert_received {:provider_ingest,
                       %{
                         id: provider_id,
                         memory_type: "document",
                         project_id: pid,
                         metadata: metadata
                       } = provider_entry}

      assert provider_id == file.id
      assert pid == project.id
      # Post-Stage 4 the provider behaviour accepts :project_id directly;
      # the legacy :workspace_id field is left nil on the wire so the
      # deprecation warning surfaces the holdouts.
      assert Map.get(provider_entry, :workspace_id) == nil
      assert metadata["file_id"] == file.id
      assert metadata["content_type"] == "text/plain"
      assert metadata["original_filename"] == "ingester-fixture.txt"

      # Regression for the SXI-markdown ingest_status=failed observed
      # 2026-06-19 — memory-service's MemoryEntry pydantic model rejects
      # any payload missing `date` (422 Unprocessable Entity). The mock
      # provider used here doesn't validate the shape, but locking the
      # presence of `:date` at this layer keeps the contract honest.
      assert is_binary(provider_entry.date),
             "build_entry/3 must include :date — memory-service rejects payloads without it"

      assert provider_entry.date =~ ~r/^\d{4}-\d{2}-\d{2}$/,
             "expected ISO-8601 date string, got #{inspect(provider_entry.date)}"

      refreshed = Files.get_file(file.id)
      assert refreshed.ingest_status == "ingested"

      assert [chunk] = Files.list_chunks_for_file(file.id)
      assert chunk.chunk_external_id == "file:" <> file.id

      assert_received {:telemetry, [:platform, :files, :ingested, :start], _, start_meta}
      assert start_meta.file_id == file.id
      assert start_meta.project_id == project.id
      assert start_meta.byte_size == byte_size("arctic photovoltaic resonance")

      assert_received {:telemetry, [:platform, :files, :ingested, :stop], measurements, stop_meta}
      assert stop_meta.dedup == false
      assert stop_meta.chunk_count == 1
      assert measurements.extracted_chars == byte_size("arctic photovoltaic resonance")
      assert is_integer(measurements.duration) and measurements.duration >= 0
    end

    test "fire-and-forget ingest_async returns :ok immediately",
         %{project: project, root: root} do
      file = create_text_file(project, root, "fire and forget body")

      assert :ok = Ingester.ingest_async(file)

      # Wait for the spawned task to finish (we can detect completion by
      # observing the provider message).
      assert_receive {:provider_ingest, %{id: id}}, 1_000
      assert id == file.id

      # Eventual consistency: poll for the row flip a couple of times.
      assert wait_for_status(file.id, "ingested")
    end
  end

  describe "content-hash dedup within a project" do
    # The platform_files schema enforces unique (content_hash, project_id)
    # — so the realistic "same bytes uploaded twice" path is the upload
    # handler returning the existing file row, NOT inserting a second
    # row. The ingester's dedup branch is the safety net for two
    # scenarios:
    #
    #   1. `ingest_async` is invoked more than once for the same file
    #      (re-run after a transient failure or operator intervention).
    #   2. Pre-existing rows from before the constraint existed (legacy
    #      data — relevant during the Stage 6 backfill).
    #
    # Both reduce to "second invocation must NOT re-call the provider
    # when an ingested sibling already exists with the same hash" — so
    # that's the invariant we test, exercised via case (1).

    test "re-invoking ingest on the same file does NOT re-call the provider",
         %{project: project, root: root} do
      body = "dedup body"

      file = create_text_file(project, root, body)
      :ok = Ingester.run(file)
      assert_received {:provider_ingest, %{id: first_id}}
      assert first_id == file.id

      first_chunks =
        file.id |> Files.list_chunks_for_file() |> Enum.map(& &1.chunk_external_id)

      assert first_chunks != []

      :ok = drain_provider_messages()

      # Reload (the ingester flipped ingest_status) and re-run.
      reloaded = Files.get_file(file.id)
      :ok = Ingester.run(reloaded)

      # The second run must NOT hit the provider — `find_ingested_sibling`
      # returns this very file row (same id, same hash, same project)
      # and the ingester short-circuits.
      refute_received {:provider_ingest, _}

      # Chunks stay the same — no new linkage rows, no duplicate inserts.
      second_chunks =
        file.id |> Files.list_chunks_for_file() |> Enum.map(& &1.chunk_external_id)

      assert first_chunks == second_chunks
    end

    test "Files.find_ingested_sibling/2 powers the dedup decision",
         %{project: project, root: root} do
      # This is the unit-level proof that the dedup hook the ingester
      # consults is reachable from outside the ingester (Stage 5 upload
      # handler will call it directly to short-circuit before insert).
      # The cross-project sibling test in
      # `Platform.FilesTest.find_ingested_sibling/2` covers project
      # isolation; here we just assert the wiring from this test
      # module's perspective.
      file = create_text_file(project, root, "sibling lookup body")
      :ok = Ingester.run(file)
      assert_receive {:provider_ingest, _}, 500

      assert sibling = Files.find_ingested_sibling(project.id, file.content_hash)
      assert sibling.id == file.id
    end
  end

  describe "cross-project re-upload of the same bytes" do
    test "ingests independently into the second project (no cross-project dedup)",
         %{project: project_a, root: root} do
      {:ok, project_b} = Tasks.create_project(%{name: "Other Project"})

      body = "cross project body"
      shared_hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      file_a =
        create_text_file(project_a, root, body,
          content_hash: shared_hash,
          filename: "a.txt"
        )

      :ok = Ingester.run(file_a)
      assert_receive {:provider_ingest, %{project_id: pid_a}}, 500
      assert pid_a == project_a.id

      :ok = drain_provider_messages()

      file_b =
        create_text_file(project_b, root, body,
          content_hash: shared_hash,
          filename: "b.txt"
        )

      :ok = Ingester.run(file_b)

      assert_receive {:provider_ingest, %{project_id: pid_b, id: id_b}}, 500
      assert pid_b == project_b.id
      assert id_b == file_b.id

      a_chunks = file_a.id |> Files.list_chunks_for_file() |> Enum.map(& &1.chunk_external_id)
      b_chunks = file_b.id |> Files.list_chunks_for_file() |> Enum.map(& &1.chunk_external_id)

      # The chunk ids must be distinct — project isolation means each
      # project gets its own embedding entry even for identical bytes.
      assert a_chunks != b_chunks
    end
  end

  describe "extract failure" do
    test "marks file :failed and emits :exception telemetry",
         %{project: project, root: root} do
      attach_telemetry([[:platform, :files, :ingested, :exception]])

      # Unsupported content_type → Extractor returns
      # {:error, {:unsupported_content_type, ct}}.
      file =
        create_text_file(project, root, "bogus body",
          content_type: "application/x-not-real",
          filename: "weird.bin"
        )

      log =
        capture_log(fn ->
          assert {:error, _} = Ingester.run(file)
        end)

      refreshed = Files.get_file(file.id)
      assert refreshed.ingest_status == "failed"

      assert_received {:telemetry, [:platform, :files, :ingested, :exception], _measurements,
                       meta}

      assert meta.file_id == file.id
      assert meta.project_id == project.id
      assert {:extract_failed, _reason} = meta.reason

      # Provider must NOT have been called when extraction fails.
      refute_received {:provider_ingest, _}

      # log var is intentionally silent — capture_log just keeps the
      # crash log out of the test output.
      _ = log
    end
  end

  describe "failure classification recorded on the row" do
    # The three categories must be MUTUALLY DISTINGUISHABLE. A test that
    # only asserts one of them passes just as happily against a classifier
    # that returns the same constant for every input, which is precisely
    # the collapse this block exists to catch — so each case refutes the
    # other two stages as well as asserting its own.
    test "an embed failure records stage=embed", %{project: project, root: root} do
      Application.put_env(:platform, :memory_service, provider: FailingProvider)
      file = create_text_file(project, root, "embeddable body")

      capture_log(fn -> assert {:error, _} = Ingester.run(file) end)

      row = Repo.get(Platform.Files.File, file.id)
      assert row.ingest_status == "failed"
      assert row.ingest_failure_stage == "embed"
      refute row.ingest_failure_stage == "extract"
      refute row.ingest_failure_stage == "storage"
      assert row.ingest_failure_detail =~ "connect timed out after 5000ms"
    end

    test "an unreadable document records stage=extract", %{project: project, root: root} do
      file =
        create_text_file(project, root, "bogus body",
          content_type: "application/x-not-real",
          filename: "weird.bin"
        )

      capture_log(fn -> assert {:error, _} = Ingester.run(file) end)

      row = Repo.get(Platform.Files.File, file.id)
      assert row.ingest_failure_stage == "extract"
      refute row.ingest_failure_stage == "embed"
      refute row.ingest_failure_stage == "storage"
    end

    test "missing bytes record stage=storage, not extract", %{project: project, root: root} do
      file = create_text_file(project, root, "body that will vanish")

      # We never GET the bytes: the row is fine, the store is not. This is
      # the re-homed case — it arrives through the extractor's error
      # channel and would otherwise be indistinguishable from a document
      # we could not read.
      File.rm!(Path.join(root, file.storage_key))

      capture_log(fn -> assert {:error, _} = Ingester.run(file) end)

      row = Repo.get(Platform.Files.File, file.id)
      assert row.ingest_failure_stage == "storage"
      refute row.ingest_failure_stage == "extract"
      refute row.ingest_failure_stage == "embed"
    end

    test "a later success clears both reason columns and the count",
         %{project: project, root: root} do
      Application.put_env(:platform, :memory_service, provider: FailingProvider)
      file = create_text_file(project, root, "retryable body")

      capture_log(fn -> assert {:error, _} = Ingester.run(file) end)

      failed = Repo.get(Platform.Files.File, file.id)
      assert failed.ingest_failure_stage == "embed"
      assert failed.ingest_failure_count == 1

      Application.put_env(:platform, :memory_service, provider: BroadcastProvider)
      assert :ok = Ingester.run(Files.get_file(file.id))

      cleared = Repo.get(Platform.Files.File, file.id)
      assert cleared.ingest_status == "ingested"
      assert is_nil(cleared.ingest_failure_stage)
      assert is_nil(cleared.ingest_failure_detail)
      assert cleared.ingest_failure_count == 0
    end

    test "a pending re-queue between the two does NOT clear the reason",
         %{project: project, root: root} do
      Application.put_env(:platform, :memory_service, provider: FailingProvider)
      file = create_text_file(project, root, "requeued body")

      capture_log(fn -> assert {:error, _} = Ingester.run(file) end)

      failed = Repo.get(Platform.Files.File, file.id)
      {:ok, _} = Files.update_ingest_status(failed, "pending")

      requeued = Repo.get(Platform.Files.File, file.id)
      assert requeued.ingest_status == "pending"
      assert requeued.ingest_failure_stage == failed.ingest_failure_stage
      assert requeued.ingest_failure_detail == failed.ingest_failure_detail
    end
  end

  describe "ingest_intent gate in ingest_async/1" do
    test "attempt file extracts, human_only file does not (positive control + refutation)",
         %{project: project, root: root} do
      attach_telemetry([[:platform, :files, :ingested, :start]])

      attempt_file = create_text_file(project, root, "attempt body worth indexing")

      human_file =
        create_text_file(project, root, "human only body",
          filename: "handbook.txt",
          content_hash: fake_hash("human only body", project.id)
        )

      {:ok, human_file} = Files.set_ingest_intent(human_file, "human_only")

      # ── Positive control: the attempt file DOES reach the pipeline.
      # Without this half, the refutation below would pass in a build
      # where nothing is ever enqueued for any file at all.
      assert :ok = Ingester.ingest_async(attempt_file)
      assert_receive {:provider_ingest, %{id: extracted_id}}, 2_000
      assert extracted_id == attempt_file.id

      assert_receive {:telemetry, [:platform, :files, :ingested, :start], _, start_meta}, 2_000
      assert start_meta.file_id == attempt_file.id
      assert wait_for_status(attempt_file.id, "ingested")

      drain_provider_messages()
      drain_telemetry_messages()

      # ── Refutation: the human_only file does not.
      assert :ok = Ingester.ingest_async(human_file)

      # Give a spawned task every chance to report before we conclude
      # absence — the attempt half above completed in well under this.
      refute_receive {:provider_ingest, _}, 300
      refute_received {:telemetry, [:platform, :files, :ingested, :start], _, _}
      assert Files.get_file(human_file.id).ingest_status == "not_attempted"
    end

    test "human_only file lands in the terminal not_attempted status",
         %{project: project, root: root} do
      file = create_text_file(project, root, "printed for a person")
      {:ok, file} = Files.set_ingest_intent(file, "human_only")

      assert :ok = Ingester.ingest_async(file)

      refreshed = Files.get_file(file.id)
      assert refreshed.ingest_status == "not_attempted"
      assert refreshed.ingest_intent == "human_only"
      assert Files.list_chunks_for_file(file.id) == []
    end

    test "an unrecognised intent raises rather than silently extracting",
         %{project: project, root: root} do
      file = create_text_file(project, root, "who knows")
      bogus = %{file | ingest_intent: "sideways"}

      assert_raise FunctionClauseError, fn -> Ingester.ingest_async(bogus) end
      refute_received {:provider_ingest, _}
    end
  end

  describe "Files.request_ingest/1" do
    test "flips a human_only + not_attempted row to attempt + pending and extracts",
         %{project: project, root: root} do
      file = create_text_file(project, root, "held back then released")
      {:ok, file} = Files.set_ingest_intent(file, "human_only")

      assert :ok = Ingester.ingest_async(file)
      assert Files.get_file(file.id).ingest_status == "not_attempted"
      refute_receive {:provider_ingest, _}, 200

      {:ok, requested} = Files.request_ingest(Files.get_file(file.id))

      assert requested.ingest_intent == "attempt"
      assert requested.ingest_status == "pending"

      assert_receive {:provider_ingest, %{id: id}}, 2_000
      assert id == file.id
      assert wait_for_status(file.id, "ingested")
    end

    # ── COLLAPSE DETECTOR ────────────────────────────────────────────────
    #
    # The entire reason `ingest_intent` exists as a second field is that
    # `ingest_status` alone cannot answer "should this file ever have
    # been ingested?". These two rows are built to be indistinguishable
    # under any single-field design that folds intent into status:
    #
    #   * retryable: intent=attempt,     status=failed        (tried, broke)
    #   * terminal:  intent=human_only,  status=not_attempted (never tried)
    #
    # Every assertion below keys on `ingest_intent`, not on status. If a
    # future refactor collapses the two fields back into one, the
    # human_only row can no longer carry "deliberately withheld" through
    # a status reset and this test fails.
    test "distinguishes a retryable failure from a deliberate human_only hold",
         %{project: project, root: root} do
      retryable =
        create_text_file(project, root, "broke on the way through", filename: "retryable.txt")

      {:ok, _} = Files.update_ingest_status(retryable, "failed")
      retryable = Files.get_file(retryable.id)

      terminal =
        create_text_file(project, root, "never meant for the index", filename: "terminal.txt")

      {:ok, terminal} = Files.set_ingest_intent(terminal, "human_only")
      assert :ok = Ingester.ingest_async(terminal)
      terminal = Files.get_file(terminal.id)

      # Preconditions: the two rows differ ONLY on intent + status, and
      # the statuses alone do not encode "deliberate".
      assert retryable.ingest_intent == "attempt"
      assert retryable.ingest_status == "failed"
      assert terminal.ingest_intent == "human_only"
      assert terminal.ingest_status == "not_attempted"

      # The terminal row got there without any extraction attempt.
      refute_receive {:provider_ingest, _}, 300
      assert Files.list_chunks_for_file(terminal.id) == []

      # Re-enqueueing the terminal row changes nothing: intent, not
      # status, is what holds it back. A single-field design has no
      # value left to hold it here.
      assert :ok = Ingester.ingest_async(terminal)
      refute_receive {:provider_ingest, _}, 300
      assert Files.get_file(terminal.id).ingest_intent == "human_only"

      # The retryable row, by contrast, is meaningfully retryable.
      {:ok, retried} = Files.request_ingest(retryable)
      assert retried.ingest_intent == "attempt"
      assert_receive {:provider_ingest, %{id: retried_id}}, 2_000
      assert retried_id == retryable.id
      assert wait_for_status(retryable.id, "ingested")

      # And request_ingest/1 is the ONLY thing that lifts the hold — the
      # assertion is on intent, which is the field a collapse deletes.
      drain_provider_messages()
      {:ok, released} = Files.request_ingest(Files.get_file(terminal.id))
      assert released.ingest_intent == "attempt"
      assert released.ingest_status == "pending"
      assert_receive {:provider_ingest, %{id: released_id}}, 2_000
      assert released_id == terminal.id
    end
  end

  # ── Local helpers ──────────────────────────────────────────────────────

  defp wait_for_status(file_id, status, attempts \\ 20) do
    Enum.reduce_while(1..attempts, false, fn _, _acc ->
      case Files.get_file(file_id) do
        %{ingest_status: ^status} -> {:halt, true}
        _ -> Process.sleep(25) && {:cont, false}
      end
    end)
  end

  defp drain_telemetry_messages do
    receive do
      {:telemetry, _, _, _} -> drain_telemetry_messages()
    after
      0 -> :ok
    end
  end

  defp drain_provider_messages do
    receive do
      {:provider_ingest, _} -> drain_provider_messages()
    after
      0 -> :ok
    end
  end
end
