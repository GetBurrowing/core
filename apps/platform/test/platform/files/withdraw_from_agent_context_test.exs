defmodule Platform.Files.WithdrawFromAgentContextTest do
  @moduledoc """
  Task 019fd033 stage 3 — withdrawing an ALREADY-EXTRACTED file from
  agent context, and the round trip back.

  Lives in its own module rather than in `Platform.FilesTest` because
  asserting the vector-index scrub means swapping
  `:memory_service, :provider` out, which is global application env —
  `Platform.FilesTest` is `async: true` and would race every other
  module using the real (disabled) provider. Same swap-the-provider
  pattern and same `async: false` as `Platform.Files.SoftDeleteTest`.

  The load-bearing shape here is the POSITIVE CONTROL. Every assertion
  after the withdrawal is an absence assertion, and an absence assertion
  over a fixture that never had the thing passes for free. So each test
  proves the text row and the chunk rows EXIST first, through a real
  ingest run, before proving they are gone.
  """

  use Platform.DataCase, async: false

  alias Platform.Files
  alias Platform.Files.Ingester
  alias Platform.Tasks

  # ── Capture provider ───────────────────────────────────────────────────

  defmodule CaptureProvider do
    @moduledoc false
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(entries, _config) do
      notify({:provider_ingest, entries})
      {:ok, length(entries)}
    end

    @impl true
    def search(_q, _o, _c), do: {:ok, []}

    @impl true
    def delete(ids, _config) do
      notify({:provider_delete, ids})
      {:ok, length(ids)}
    end

    @impl true
    def health(_c), do: :ok

    defp notify(msg) do
      case :persistent_term.get({__MODULE__, :pid}, nil) do
        nil -> :ok
        pid -> send(pid, msg)
      end
    end
  end

  # ── Setup ──────────────────────────────────────────────────────────────

  setup do
    original = Application.get_env(:platform, :memory_service, [])
    Application.put_env(:platform, :memory_service, provider: CaptureProvider)
    :persistent_term.put({CaptureProvider, :pid}, self())

    root =
      Platform.TestTemp.path("platform-files-withdraw-test")

    File.mkdir_p!(root)
    previous_root = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      Application.put_env(:platform, :memory_service, original)
      :persistent_term.erase({CaptureProvider, :pid})
      File.rm_rf!(root)

      if previous_root,
        do: Application.put_env(:platform, :chat_attachments_root, previous_root),
        else: Application.delete_env(:platform, :chat_attachments_root)
    end)

    {:ok, project} = Tasks.create_project(%{name: "Withdraw #{System.unique_integer()}"})

    {:ok, project: project, root: root}
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  # Creates a real text file on disk and runs the ingest pipeline
  # synchronously, so the fixture has a genuine `platform_file_texts` row
  # and genuine chunk rows — not hand-seeded ones. Withdrawal has to
  # survive the real shapes.
  defp ingested_file!(project, root, body) do
    n = System.unique_integer([:positive])
    filename = "withdraw-#{n}.txt"
    storage_key = "files/#{project.id}/#{Ecto.UUID.generate()}/#{filename}"
    abs_path = Path.join(root, storage_key)
    File.mkdir_p!(Path.dirname(abs_path))
    File.write!(abs_path, body)

    {:ok, file} =
      Files.create_file(%{
        project_id: project.id,
        org_id: project.org_id,
        name: filename,
        original_filename: filename,
        content_type: "text/plain",
        byte_size: byte_size(body),
        storage_key: storage_key,
        content_hash:
          :crypto.hash(:sha256, project.id <> ":" <> body) |> Base.encode16(case: :lower)
      })

    :ok = Ingester.run(file)
    Files.get_file!(file.id)
  end

  defp attach_telemetry(events) do
    handler_id = "withdraw-test-#{System.unique_integer([:positive])}"
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

  describe "withdraw_from_agent_context/1" do
    test "removes the cached text, the chunk rows and the index entry",
         %{project: project, root: root} do
      file = ingested_file!(project, root, "arctic photovoltaic resonance report")

      # POSITIVE CONTROL — without these four the assertions below are
      # vacuous: an absent row cannot be observed to disappear.
      assert file.ingest_intent == "attempt"
      assert file.ingest_status == "ingested"
      assert %Platform.Files.Text{text: text} = Files.fetch_extracted_text(file.id)
      assert text =~ "arctic photovoltaic resonance"
      assert Files.list_chunks_for_file(file.id) != []

      # Drain the ingest-side provider traffic so the delete assertion
      # below can only match a message this call produced.
      assert_received {:provider_ingest, _entries}

      assert {:ok, withdrawn} = Files.withdraw_from_agent_context(file)

      # (b) the cached extracted body — the reader that bypasses the index
      assert Files.fetch_extracted_text(file.id) == nil
      # dedup linkage
      assert Files.list_chunks_for_file(file.id) == []
      # (a) the vector index, scrubbed under the file id
      assert_received {:provider_delete, [scrubbed_id]}
      assert scrubbed_id == file.id

      # The row itself survives — this is a withdrawal, not a delete.
      assert withdrawn.id == file.id
      assert withdrawn.ingest_intent == "human_only"
      assert withdrawn.ingest_status == "not_attempted"

      reloaded = Files.get_file!(file.id)
      assert reloaded.ingest_intent == "human_only"
      assert reloaded.ingest_status == "not_attempted"
      assert reloaded.deleted_at == nil
    end

    test "broadcasts on the project topic so open Files pages re-render",
         %{project: project, root: root} do
      file = ingested_file!(project, root, "broadcast fixture body")
      :ok = Files.subscribe_project(project.id)

      assert {:ok, _} = Files.withdraw_from_agent_context(file)

      file_id = file.id
      assert_receive {:file_withdrawn_from_agent_context, ^file_id}
    end

    test "is idempotent — withdrawing an already-withdrawn file is a no-op success",
         %{project: project, root: root} do
      file = ingested_file!(project, root, "idempotent fixture body")
      assert {:ok, withdrawn} = Files.withdraw_from_agent_context(file)

      assert {:ok, again} = Files.withdraw_from_agent_context(withdrawn)
      assert again.ingest_intent == "human_only"
      assert again.ingest_status == "not_attempted"
      assert Files.fetch_extracted_text(file.id) == nil
    end
  end

  describe "restore_to_agent_context/1 — the round trip" do
    test "re-EXTRACTS rather than re-indexing from the cache the withdrawal deleted",
         %{project: project, root: root} do
      file = ingested_file!(project, root, "round trip resonance body")

      assert {:ok, withdrawn} = Files.withdraw_from_agent_context(file)
      # The cache `restore_file/2` would have re-indexed from is gone —
      # this is what makes re-extraction the only correct inverse.
      assert Files.fetch_extracted_text(file.id) == nil

      attach_telemetry([
        [:platform, :files, :ingested, :start],
        [:platform, :files, :ingested, :stop]
      ])

      assert {:ok, restored} = Files.restore_to_agent_context(withdrawn)
      assert restored.ingest_intent == "attempt"
      assert restored.ingest_status == "pending"

      file_id = file.id

      assert_receive {:telemetry, [:platform, :files, :ingested, :start], _measurements,
                      %{file_id: ^file_id}}

      # The re-ingest runs async under the TaskSupervisor; wait for it to
      # resolve rather than racing it with the cache read below.
      assert_receive {:telemetry, [:platform, :files, :ingested, :stop], _m,
                      %{file_id: ^file_id}},
                     5_000

      # And extraction actually re-populated the cache it had deleted.
      assert %Platform.Files.Text{text: text} = Files.fetch_extracted_text(file.id)
      assert text =~ "round trip resonance body"
      assert Files.get_file!(file.id).ingest_status == "ingested"
    end
  end
end
