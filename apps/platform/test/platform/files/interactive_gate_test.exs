defmodule Platform.Files.InteractiveGateTest do
  @moduledoc """
  Task 01a06a20 stage 1 — the gate that decides whether a file may run
  its own code.

  Invariants under test:

    1. `mark_interactive/2` sets `interactive_at` + `interactive_by_user_id`
       (actor-attributed) and emits the bridged
       `[:platform, :files, :file_interactive_marked]` audit event.
       `unmark_interactive/2` is the inverse, clearing both fields
       together and emitting `[:platform, :files, :file_interactive_unmarked]`.
    2. Actor-first: a missing/anonymous actor is `:unauthorized` before
       any write; an archived project is `:project_archived`; the
       toggle-pair guards (`:already_interactive` / `:not_interactive`)
       refuse a redundant flip.
    3. **Binding constraint** — `interactive_at` / `interactive_by_user_id`
       are unreachable through `File.changeset/2`'s cast: passing them as
       params never persists, proven on the PERSISTED struct, not on
       changeset validity.
    4. **Binding constraint** — `Platform.Files` has no `update_file/2`,
       and no public function in this module writes `storage_key` on an
       EXISTING row. Every function that mutates a `platform_files` row
       after insert is exercised here and checked against the row's
       original `storage_key`, so a future writer that starts casting
       `storage_key` post-insert breaks this test.
    5. **Mutation probe** (manual, not automated here) — deleting the
       `ensure_actor` call inside `mark_interactive/2` must fail the
       "rejects a missing or anonymous actor" test below. See the task
       report for the result of that probe; it is not left in the
       committed source.

  Uses the same swap-`:provider`-out pattern as `Platform.Files.SoftDeleteTest`
  (the suite isn't wired for Mox) for the `delete_file/2` / `restore_file/2`
  calls exercised by the storage_key pin, so this module is `async: false`.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Audit
  alias Platform.Files
  alias Platform.Files.File, as: PlatformFile
  alias Platform.Repo
  alias Platform.Tasks

  # ── Capture provider (delete_file/2 + restore_file/2 touch Memory) ─────

  defmodule CaptureProvider do
    @moduledoc false
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(entries, _config) do
      pid = :persistent_term.get({__MODULE__, :pid}, nil)
      if pid, do: Enum.each(entries, &send(pid, {:provider_ingest, &1}))
      {:ok, length(entries)}
    end

    @impl true
    def search(_q, _o, _c), do: {:ok, []}

    @impl true
    def delete(ids, _config) do
      pid = :persistent_term.get({__MODULE__, :pid}, nil)
      if pid, do: send(pid, {:provider_delete, ids})
      {:ok, length(ids)}
    end

    @impl true
    def health(_c), do: :ok
  end

  # ── Setup ──────────────────────────────────────────────────────────────

  setup do
    original = Application.get_env(:platform, :memory_service, [])
    Application.put_env(:platform, :memory_service, provider: CaptureProvider)
    :persistent_term.put({CaptureProvider, :pid}, self())

    # Guarantee the telemetry→audit bridge is attached so the new
    # `[:platform, :files, :file_interactive_*]` events actually persist.
    # If either is missing from TelemetryHandler @events the row silently
    # won't exist — which the audit-row tests below would then catch.
    Platform.Audit.TelemetryHandler.detach()
    Platform.Audit.TelemetryHandler.attach()

    on_exit(fn ->
      Application.put_env(:platform, :memory_service, original)
      :persistent_term.erase({CaptureProvider, :pid})
      Platform.Audit.TelemetryHandler.detach()
      Platform.Audit.TelemetryHandler.attach()
    end)

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp u, do: System.unique_integer([:positive])

  defp user_fixture! do
    n = u()

    Repo.insert!(%Platform.Accounts.User{
      name: "Interactive Gate User #{n}",
      email: "interactive-gate-#{n}@example.com",
      oidc_sub: "interactive-gate-sub-#{n}"
    })
  end

  # A real, persisted user — `interactive_by_user_id` is a genuine FK to
  # `users`, unlike `deleted_at`'s bare timestamp, so the actor map here
  # must resolve to a real row or the DB rejects the write.
  defp actor do
    %{id: user_fixture!().id}
  end

  defp project! do
    {:ok, project} = Tasks.create_project(%{name: "Interactive Gate #{u()}"})
    project
  end

  defp file!(project, overrides \\ %{}) do
    n = u()

    attrs =
      Map.merge(
        %{
          project_id: project.id,
          name: "Doc #{n}",
          original_filename: "doc-#{n}.txt",
          content_type: "text/plain",
          byte_size: 42,
          storage_key: "files/#{project.id}/#{n}/doc.txt",
          content_hash: :crypto.hash(:sha256, "doc-#{n}") |> Base.encode16(case: :lower)
        },
        overrides
      )

    {:ok, file} = Files.create_file(attrs)
    file
  end

  defp archive_project!(project) do
    project
    |> Platform.Tasks.Project.changeset(%{archived_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  # ── mark_interactive/2 ───────────────────────────────────────────────

  describe "mark_interactive/2" do
    test "marks the row and returns the updated struct" do
      file = file!(project!())
      user = actor()

      assert {:ok, %PlatformFile{} = marked} = Files.mark_interactive(user, file)
      assert %DateTime{} = marked.interactive_at
      assert marked.interactive_by_user_id == user.id
      assert marked.id == file.id
    end

    test "persists a bridged audit row with the actor attributed" do
      user = actor()
      file = file!(project!())

      assert {:ok, _} = Files.mark_interactive(user, file)

      assert [event] = Audit.list(event_type: "platform.files.file_interactive_marked")
      assert event.actor_id == user.id
      assert event.actor_type == "user"
      assert event.resource_type == "file"
      assert event.resource_id == file.id
      assert event.action == "file_interactive_marked"
      assert event.metadata["project_id"] == file.project_id
    end

    test "rejects a missing or anonymous actor before any write" do
      file = file!(project!())

      assert {:error, :unauthorized} = Files.mark_interactive(nil, file)
      assert {:error, :unauthorized} = Files.mark_interactive(%{}, file)

      assert %PlatformFile{interactive_at: nil, interactive_by_user_id: nil} =
               Files.get_file(file.id)
    end

    test "rejects an already-interactive file" do
      file = file!(project!())
      assert {:ok, marked} = Files.mark_interactive(actor(), file)
      assert {:error, :already_interactive} = Files.mark_interactive(actor(), marked)
    end

    test "refuses a file in an archived project" do
      project = project!()
      file = file!(project)
      archive_project!(project)

      assert {:error, :project_archived} = Files.mark_interactive(actor(), file)
    end
  end

  # ── unmark_interactive/2 ─────────────────────────────────────────────

  describe "unmark_interactive/2" do
    test "clears both fields together" do
      file = file!(project!())
      assert {:ok, marked} = Files.mark_interactive(actor(), file)

      assert {:ok, %PlatformFile{} = unmarked} = Files.unmark_interactive(actor(), marked)
      assert unmarked.interactive_at == nil
      assert unmarked.interactive_by_user_id == nil
      assert unmarked.id == file.id
    end

    test "persists a bridged audit row with the actor attributed" do
      file = file!(project!())
      assert {:ok, marked} = Files.mark_interactive(actor(), file)

      unmarker = actor()
      assert {:ok, _} = Files.unmark_interactive(unmarker, marked)

      assert [event] = Audit.list(event_type: "platform.files.file_interactive_unmarked")
      assert event.actor_id == unmarker.id
      assert event.actor_type == "user"
      assert event.resource_type == "file"
      assert event.resource_id == file.id
      assert event.action == "file_interactive_unmarked"
    end

    test "rejects a file that is not interactive" do
      file = file!(project!())
      assert {:error, :not_interactive} = Files.unmark_interactive(actor(), file)
    end

    test "rejects a missing actor" do
      file = file!(project!())
      assert {:ok, marked} = Files.mark_interactive(actor(), file)
      assert {:error, :unauthorized} = Files.unmark_interactive(nil, marked)
    end

    test "refuses a file in an archived project" do
      project = project!()
      file = file!(project)
      assert {:ok, marked} = Files.mark_interactive(actor(), file)
      archive_project!(project)

      assert {:error, :project_archived} = Files.unmark_interactive(actor(), marked)
    end
  end

  # ── Binding constraint: unreachable through File.changeset/2 ──────────

  describe "the interactive gate is unreachable through File.changeset/2" do
    test "params for interactive_at / interactive_by_user_id never persist" do
      file = file!(project!())
      other_user = user_fixture!()

      changeset =
        PlatformFile.changeset(file, %{
          interactive_at: DateTime.utc_now(),
          interactive_by_user_id: other_user.id
        })

      # Not a claim about the changeset's validity — a cast() that simply
      # ignores unlisted params produces a "valid" changeset too. The
      # claim under test is what actually lands in Postgres.
      assert {:ok, persisted} = Repo.update(changeset)
      assert persisted.interactive_at == nil
      assert persisted.interactive_by_user_id == nil

      reloaded = Repo.get!(PlatformFile, file.id)
      assert reloaded.interactive_at == nil
      assert reloaded.interactive_by_user_id == nil
    end
  end

  # ── Binding constraint: no writer touches storage_key post-insert ─────

  describe "storage_key is unreachable on an existing row" do
    test "Platform.Files exports no update_file/2 (or any arity)" do
      exported = Platform.Files.__info__(:functions)
      refute Enum.any?(exported, fn {name, _arity} -> name == :update_file end)
    end

    test "every File-row mutator in Platform.Files leaves storage_key untouched" do
      project = project!()
      file = file!(project)
      original_storage_key = file.storage_key

      assert_storage_key_unchanged = fn label ->
        current = Repo.get!(PlatformFile, file.id)

        assert current.storage_key == original_storage_key,
               "#{label} changed storage_key: #{inspect(current.storage_key)}"
      end

      # update_ingest_status/2 and /3 — the ingest outcome writer.
      {:ok, file} = Files.update_ingest_status(file, "failed")
      assert_storage_key_unchanged.("update_ingest_status/2 (failed)")

      {:ok, file} =
        Files.update_ingest_status(file, "failed", failure_stage: :extract, failure_detail: "x")

      assert_storage_key_unchanged.("update_ingest_status/3 (failed + reason)")

      {:ok, file} = Files.update_ingest_status(file, "ingested")
      assert_storage_key_unchanged.("update_ingest_status/2 (ingested)")

      # mark_card_generated/2 — the catalog-card backlink writer.
      {:ok, file} = Files.mark_card_generated(file, "project/#{project.id}/page/files/x.md")
      assert_storage_key_unchanged.("mark_card_generated/2")

      # set_ingest_intent/2 — the operator-decision writer.
      {:ok, file} = Files.set_ingest_intent(file, "human_only")
      assert_storage_key_unchanged.("set_ingest_intent/2")

      # request_ingest/2 (:sync) — the retry/override entry point. The
      # row's bytes were never written to storage, so extraction fails
      # deterministically and synchronously; only the outcome is
      # uncertain, not whether storage_key moved.
      capture_log(fn ->
        Files.request_ingest(file, mode: :sync)
      end)

      assert_storage_key_unchanged.("request_ingest/2 (:sync)")
      file = Files.get_file(file.id)

      # mark_interactive/2 / unmark_interactive/2 — this stage's own
      # writers, the ones with the most direct motive to touch the row.
      {:ok, file} = Files.mark_interactive(actor(), file)
      assert_storage_key_unchanged.("mark_interactive/2")

      {:ok, file} = Files.unmark_interactive(actor(), file)
      assert_storage_key_unchanged.("unmark_interactive/2")

      # delete_file/2 / restore_file/2 — the soft-delete pair.
      {:ok, file} = Files.delete_file(actor(), file)
      assert_storage_key_unchanged.("delete_file/2")

      {:ok, _file} = Files.restore_file(actor(), file)
      assert_storage_key_unchanged.("restore_file/2")
    end
  end
end
