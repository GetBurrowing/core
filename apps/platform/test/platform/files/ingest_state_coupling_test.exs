defmodule Platform.Files.IngestStateCouplingTest do
  @moduledoc """
  Task 019fd318 — proves the DB-level coupling between
  `platform_files.ingest_intent` and `platform_files.ingest_status`.

  ## Why the first assertion goes around the application

  The obvious test — "an incoherent row raises" — is VACUOUS once the fix
  lands, because a successful fix is exactly what makes the fixture
  unbuildable through `File.changeset/2`. A test that constructs the row
  through the app proves only that the app refuses it, which is a
  convention, not a guarantee. So the rejection probe issues raw SQL with
  `Repo.query/2` and asserts Postgres itself refuses the write.

  ## And the inverse trap

  A constraint-killed probe proves nothing about THIS constraint. A NOT
  NULL violation, a missing FK, or the pre-existing content-hash /
  ingest-status checks would all produce a red that looks identical. So
  the probe asserts on the constraint NAME, and it builds its row by
  copying a legitimately-inserted file's own column values so the pair is
  the ONLY thing wrong with it. The companion assertion — the same raw
  INSERT with `human_only` SUCCEEDS — is what proves the rejection came
  from the coupling rather than from the row's shape.

  ## And the positive control

  A constraint written as `false` would pass the rejection probe
  perfectly. So every pair the rule permits is asserted to still insert
  and round-trip, including the `human_only` + {pending, ingested,
  failed} intermediates that `withdraw_from_agent_context/1` passes
  through inside its transaction.
  """

  use Platform.DataCase, async: false

  alias Platform.Files
  alias Platform.Files.File, as: FileSchema
  alias Platform.Files.Ingester
  alias Platform.Repo
  alias Platform.Tasks

  @constraint "platform_files_not_attempted_requires_human_only_check"

  # ── Capture provider ───────────────────────────────────────────────────
  # Mirrors Platform.Files.WithdrawFromAgentContextTest: the round-trip
  # assertion runs a real ingest, which must not reach a live memory
  # service. Swapping the provider is global application env, hence
  # `async: false`.

  defmodule CaptureProvider do
    @moduledoc false
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(entries, _config), do: {:ok, length(entries)}

    @impl true
    def search(_q, _o, _c), do: {:ok, []}

    @impl true
    def delete(ids, _config), do: {:ok, length(ids)}

    @impl true
    def health(_c), do: :ok
  end

  setup do
    original = Application.get_env(:platform, :memory_service, [])
    Application.put_env(:platform, :memory_service, provider: CaptureProvider)

    root =
      Path.join(
        System.tmp_dir!(),
        "platform-ingest-coupling-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    previous_root = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      Application.put_env(:platform, :memory_service, original)
      File.rm_rf!(root)

      if previous_root,
        do: Application.put_env(:platform, :chat_attachments_root, previous_root),
        else: Application.delete_env(:platform, :chat_attachments_root)
    end)

    {:ok, project} = Tasks.create_project(%{name: "Coupling #{System.unique_integer()}"})

    {:ok, project: project, root: root}
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp legit_file!(project, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, file} =
      Files.create_file(
        Map.merge(
          %{
            project_id: project.id,
            org_id: project.org_id,
            name: "coupling-#{n}.txt",
            original_filename: "coupling-#{n}.txt",
            content_type: "text/plain",
            byte_size: 12,
            storage_key: "files/#{project.id}/#{Ecto.UUID.generate()}/coupling-#{n}.txt",
            content_hash: :crypto.hash(:sha256, "coupling-#{n}") |> Base.encode16(case: :lower)
          },
          attrs
        )
      )

    file
  end

  # Raw INSERT that bypasses Ecto changesets entirely. Every column is
  # copied from `template` (a row the app already accepted) except the
  # unique keys and the intent/status pair under test, so the pair is the
  # only thing that can be wrong with the row.
  defp raw_insert(template, intent, status) do
    n = System.unique_integer([:positive])

    Repo.query(
      """
      INSERT INTO platform_files
        (id, project_id, org_id, name, original_filename, content_type,
         byte_size, storage_key, content_hash, ingest_status, ingest_intent,
         inserted_at, updated_at)
      VALUES
        ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, now(), now())
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(template.project_id),
        template.org_id && Ecto.UUID.dump!(template.org_id),
        "raw-#{n}.txt",
        template.original_filename,
        template.content_type,
        template.byte_size,
        "#{template.storage_key}-raw-#{n}",
        :crypto.hash(:sha256, "raw-#{n}") |> Base.encode16(case: :lower),
        status,
        intent
      ]
    )
  end

  # Local, as in every other test module in this tree — `Platform.DataCase`
  # does not provide it.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  # ── 1. Raw rejection ───────────────────────────────────────────────────

  describe "the database refuses attempt + not_attempted" do
    test "a raw INSERT of the incoherent pair is rejected by name", %{project: project} do
      template = legit_file!(project)

      assert {:error, %Postgrex.Error{postgres: %{constraint: constraint}}} =
               raw_insert(template, "attempt", "not_attempted")

      # Asserting the NAME, not merely that an error occurred: a NOT NULL
      # violation, an FK miss, or the pre-existing content_hash /
      # ingest_status checks would all be red for the wrong reason.
      assert constraint == @constraint
    end

    test "the identical raw INSERT with human_only succeeds", %{project: project} do
      template = legit_file!(project)

      # This is what proves the rejection above came from the coupling and
      # not from the shape of the row the probe builds.
      assert {:ok, %Postgrex.Result{num_rows: 1}} =
               raw_insert(template, "human_only", "not_attempted")
    end
  end

  # ── 2. Positive control ────────────────────────────────────────────────

  describe "every pair the rule permits still round-trips" do
    # Seven pairs, not four: the `human_only` clause of the constraint
    # matches against ANY status. The three `human_only` + non-terminal
    # pairs are the intermediates `withdraw_from_agent_context/1` passes
    # through inside its transaction — a constraint tightened into a
    # biconditional would abort that transaction.
    @legal_pairs [
      {"attempt", "pending"},
      {"attempt", "ingested"},
      {"attempt", "failed"},
      {"human_only", "not_attempted"},
      {"human_only", "pending"},
      {"human_only", "ingested"},
      {"human_only", "failed"}
    ]

    for {intent, status} <- @legal_pairs do
      test "#{intent} + #{status} inserts and reads back intact", %{project: project} do
        intent = unquote(intent)
        status = unquote(status)

        file = legit_file!(project, %{ingest_intent: intent, ingest_status: status})

        reloaded = Files.get_file(file.id)

        # Read-back values, not just {:ok, _}: a write that silently
        # coerced the pair would pass a bare success assertion.
        assert reloaded.ingest_intent == intent
        assert reloaded.ingest_status == status
      end
    end

    test "the illegal pair is the ONLY one File.changeset/2 refuses", %{project: project} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               %FileSchema{}
               |> FileSchema.changeset(%{
                 project_id: project.id,
                 content_type: "text/plain",
                 byte_size: 1,
                 storage_key: "files/#{project.id}/#{Ecto.UUID.generate()}/illegal.txt",
                 content_hash: String.duplicate("a", 64),
                 ingest_intent: "attempt",
                 ingest_status: "not_attempted"
               })
               |> Repo.insert()

      assert %{ingest_status: [message]} = errors_on(changeset)
      assert message =~ "not_attempted"
    end
  end

  # ── 3. Round-trip regression ───────────────────────────────────────────

  describe "withdraw → restore round trip" do
    test "an ingested file survives withdrawal and restoration",
         %{project: project, root: root} do
      body = "coupling round trip fixture body"
      n = System.unique_integer([:positive])
      filename = "roundtrip-#{n}.txt"
      storage_key = "files/#{project.id}/#{Ecto.UUID.generate()}/#{filename}"
      abs_path = Path.join(root, storage_key)
      File.mkdir_p!(Path.dirname(abs_path))
      File.write!(abs_path, body)

      {:ok, created} =
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

      :ok = Ingester.run(created)
      file = Files.get_file!(created.id)

      # POSITIVE CONTROL — without this the withdrawal below could be
      # "succeeding" against a row that was never ingested.
      assert file.ingest_intent == "attempt"
      assert file.ingest_status == "ingested"

      # The withdrawal transaction writes intent FIRST, status SECOND, so
      # it passes through `human_only` + `ingested`. A constraint written
      # as a biconditional would roll the whole transaction back here.
      assert {:ok, withdrawn} = Files.withdraw_from_agent_context(file)
      assert withdrawn.ingest_intent == "human_only"
      assert withdrawn.ingest_status == "not_attempted"

      assert {:ok, restored} = Files.restore_to_agent_context(withdrawn)
      assert restored.ingest_intent == "attempt"
      refute restored.ingest_status == "not_attempted"

      reloaded = Files.get_file!(created.id)
      assert reloaded.ingest_intent == "attempt"
      refute reloaded.ingest_status == "not_attempted"
    end
  end
end
