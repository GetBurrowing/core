defmodule Platform.Federation.ToolSurfaceHumanOnlyContextTest do
  @moduledoc """
  The point of the human-only audience control, asserted as ONE unit
  (task 019fd033).

  "Human-only content does not appear in agent context" passes perfectly
  for an implementation that DROPS the file from the listing entirely —
  which is the design that was considered and rejected. Hiding the row
  makes an agent answer "I don't know of any such file" seconds after a
  person shared it. A refutation alone cannot tell the correct behaviour
  apart from the harmful one, so the guard here is a TRIO:

    1. CONTENT ABSENT   — `file_get_text` withholds the body on both the
                          text and the `binary: true` branch, and
                          `file_search` drops the row.
    2. METADATA PRESENT — `file_list` still returns the row, by name,
                          with `ingest_intent: "human_only"` and a
                          non-nil `agent_content_note`. This is the
                          assertion the rejected design fails.
    3. POSITIVE CONTROL — a normal file's content IS still served.
                          Without it, a gate that broke every read would
                          pass 1 and 2.

  Every assertion is keyed on the map returned by
  `Platform.Federation.ToolSurface.execute/3` — the payload an agent
  actually receives. A list of structs out of `Files.list_files_for_project/2`
  is not agent context, and asserting on one would not see a regression
  in the assembly step between them.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Federation.ToolSurface
  alias Platform.Files
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy

  # The two distinctive strings are deliberately UNRELATED to each other
  # (no shared substring, no shared stem), so neither assertion can pass
  # by accidentally matching the other row's data.
  @readable_marker "ZEPHYR-CATALOG-4417"
  @readable_filename "release-notes.txt"
  @human_only_body "quokka lantern briefing, 9082 attendees"
  @human_only_filename "board-offsite-recording.mov"

  # Stub memory provider — mirrors the one in tool_surface_files_test.exs
  # so file_search can be exercised without the embedding service.
  defmodule MemoryStub do
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(_entries, _config), do: {:ok, 0}

    @impl true
    def search(_query, _opts, config) do
      case Keyword.get(config, :search_results, []) do
        {:error, _reason} = err -> err
        list when is_list(list) -> {:ok, list}
      end
    end

    @impl true
    def delete(_ids, _config), do: {:ok, 0}

    @impl true
    def health(_c), do: :ok
  end

  defp install_memory_stub(results) do
    prev = Application.get_env(:platform, :memory_service, [])
    Application.put_env(:platform, :memory_service, provider: MemoryStub, search_results: results)
    on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)
    :ok
  end

  # ── Setup ──────────────────────────────────────────────────────────────

  setup do
    root = ensure_root_org()
    org = ensure_tenant_org("human-only-ctx-#{u()}", root)
    {:ok, project} = Tasks.create_project(%{name: "Proj #{u()}", org_id: org.id})
    agent = create_agent("human-only-ctx-agent", %{"org_id" => org.id})

    # File A — the ordinary case. Extracted, readable, carries a marker
    # nothing else in the fixture contains.
    readable =
      create_file(project,
        filename: @readable_filename,
        text: "quarterly summary. #{@readable_marker}. end of summary.",
        ingest_intent: "attempt",
        ingest_status: "ingested"
      )

    # File B — human-only, never attempted. It KEEPS a cached text row on
    # purpose: `Files.withdraw_from_agent_context/1` scrubs that row, so a
    # fixture without one would leave the read-time gate untested (the
    # refusal would come from an empty table, not from the gate). The
    # dedup-copy case in tool_surface.ex is exactly this shape.
    withheld =
      create_file(project,
        filename: @human_only_filename,
        content_type: "video/quicktime",
        text: @human_only_body,
        ingest_intent: "human_only",
        ingest_status: "not_attempted"
      )

    {:ok, %{org: org, project: project, agent: agent, readable: readable, withheld: withheld}}
  end

  # ── 1. CONTENT ABSENT ─────────────────────────────────────────────────

  describe "human-only content is absent from agent context" do
    test "file_get_text refuses the body and returns no text key",
         %{agent: agent, withheld: withheld} do
      # Measured, not assumed: the body IS in the store the tool reads
      # from, so the refusal below is the gate firing.
      assert %Platform.Files.Text{text: @human_only_body} =
               Files.fetch_extracted_text(withheld.id)

      assert {:error, payload} =
               ToolSurface.execute(
                 "file_get_text",
                 %{"file_id" => withheld.id},
                 context_for(agent)
               )

      assert payload.code == :human_only
      # Key ABSENCE, not merely an error tuple — a payload that both
      # errors and carries the body is the bug this guards.
      refute Map.has_key?(payload, :text)
      refute Map.has_key?(payload, :data_base64)
      refute inspect(payload) =~ "quokka"
    end

    test "file_search returns no hit for the human-only file even when the index still has it",
         %{agent: agent, project: project, readable: readable, withheld: withheld} do
      # The stub returns BOTH ids — the vector-index scrub is modelled as
      # not having run, so the exclusion below is not true by construction.
      install_memory_stub([
        %{entry_id: readable.id, score: 0.90},
        %{entry_id: withheld.id, score: 0.99}
      ])

      assert {:ok, %{hits: hits, count: count}} =
               ToolSurface.execute(
                 "file_search",
                 %{"project_id" => project.id, "query" => "quokka lantern briefing"},
                 context_for(agent)
               )

      assert count == 1
      assert Enum.map(hits, & &1.file_id) == [readable.id]
      # Both sides: the hit is gone AND its body did not leak as a
      # snippet hung off the surviving hit.
      refute Enum.any?(hits, fn h -> to_string(h.snippet) =~ "quokka" end)
    end
  end

  describe "human-only content is absent from agent context — binary branch" do
    setup :with_tmp_storage_root

    test "file_get_text with binary: true returns :human_only and NO data_base64 key",
         %{agent: agent, project: project} do
      bytes = "raw #{@human_only_body} bytes"
      file = create_file_with_bytes(project, bytes, filename: @human_only_filename)

      # Positive control on the fixture itself: the bytes really are
      # retrievable, so the refusal is the gate and not a missing blob.
      assert {:ok, stream} = Platform.Files.Storage.get(file.storage_key)
      assert Enum.join(stream, "") == bytes

      assert {:error, payload} =
               ToolSurface.execute(
                 "file_get_text",
                 %{"file_id" => file.id, "binary" => true},
                 context_for(agent)
               )

      assert payload.code == :human_only
      refute Map.has_key?(payload, :data_base64)
      refute inspect(payload) =~ "quokka"
    end
  end

  # ── 2. METADATA PRESENT ───────────────────────────────────────────────

  describe "human-only metadata IS present in agent context" do
    # THE assertion the rejected "drop the row" design fails. If this
    # goes green under an implementation that hides human_only files
    # from file_list, the test is keyed on the wrong observable.
    test "file_list returns the human-only row by filename, flagged and annotated",
         %{agent: agent, project: project, withheld: withheld} do
      assert {:ok, %{files: files, count: count}} =
               ToolSurface.execute(
                 "file_list",
                 %{"project_id" => project.id},
                 context_for(agent)
               )

      row = Enum.find(files, &(&1.id == withheld.id))

      assert row,
             "file_list dropped the human-only row entirely — that is the rejected design: " <>
               "an agent would tell the user no such file exists. Got: #{inspect(files)}"

      # The filename is the observable an agent uses to tell a human the
      # file exists. Assert it explicitly, by equality.
      assert row.original_filename == @human_only_filename
      assert row.ingest_intent == "human_only"
      assert row.agent_content_available == false
      # Non-nil note: a bare `false` reads to an agent like a broken
      # file, which produces the same wrong answer as hiding the row.
      refute is_nil(row.agent_content_note)
      assert row.agent_content_note =~ "human-only"
      # Checked LAST, deliberately. A count assertion placed first fails
      # under the drop-the-row mutation before the filename assertion is
      # ever reached, and the failure message then reads "1 != 2" rather
      # than naming the behaviour that broke.
      assert count == 2
    end

    test "file_get_metadata also returns the human-only row rather than :not_found",
         %{agent: agent, withheld: withheld} do
      assert {:ok, meta} =
               ToolSurface.execute(
                 "file_get_metadata",
                 %{"file_id" => withheld.id},
                 context_for(agent)
               )

      assert meta.original_filename == @human_only_filename
      assert meta.ingest_intent == "human_only"
      assert meta.agent_content_available == false
      refute is_nil(meta.agent_content_note)
    end
  end

  # ── 3. POSITIVE CONTROL ───────────────────────────────────────────────

  describe "ordinary files are unaffected" do
    # Without this, a gate that broke EVERY read would sail through both
    # of the assertions above.
    test "file_get_text still returns the marker for an attempt/ingested file",
         %{agent: agent, readable: readable} do
      assert {:ok, payload} =
               ToolSurface.execute(
                 "file_get_text",
                 %{"file_id" => readable.id},
                 context_for(agent)
               )

      assert payload.file_id == readable.id
      assert payload.text =~ @readable_marker
    end

    test "file_list marks the ordinary file as readable",
         %{agent: agent, project: project, readable: readable} do
      assert {:ok, %{files: files}} =
               ToolSurface.execute(
                 "file_list",
                 %{"project_id" => project.id},
                 context_for(agent)
               )

      row = Enum.find(files, &(&1.id == readable.id))

      assert row.original_filename == @readable_filename
      assert row.ingest_intent == "attempt"
      assert row.agent_content_available == true
      assert is_nil(row.agent_content_note)
    end
  end

  # ── Fixtures ──────────────────────────────────────────────────────────

  defp u, do: System.unique_integer([:positive])

  defp ensure_root_org do
    case Repo.get_by(Tenancy.Org, slug: "fabrikam") do
      nil ->
        {:ok, org} =
          %Tenancy.Org{}
          |> Tenancy.Org.changeset(%{slug: "fabrikam", name: "Fabrikam", parent_org_id: nil})
          |> Repo.insert()

        org

      org ->
        org
    end
  end

  defp ensure_tenant_org(slug, root) do
    {:ok, org} =
      %Tenancy.Org{}
      |> Tenancy.Org.changeset(%{slug: slug, name: slug, parent_org_id: root.id})
      |> Repo.insert()

    org
  end

  defp create_agent(slug_prefix, metadata) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "#{slug_prefix}-#{System.unique_integer([:positive, :monotonic])}",
        name: "Human Only Ctx Agent",
        status: "active",
        metadata: metadata
      })
      |> Repo.insert()

    agent
  end

  defp context_for(%Agent{id: id}), do: %{agent_id: id}

  defp create_file(project, opts) do
    filename = Keyword.fetch!(opts, :filename)
    content_type = Keyword.get(opts, :content_type, "text/plain")
    body = Keyword.get(opts, :body, "body-#{u()}")

    hash =
      :crypto.hash(:sha256, project.id <> ":" <> body <> ":" <> filename)
      |> Base.encode16(case: :lower)

    {:ok, file} =
      Files.create_file(%{
        project_id: project.id,
        org_id: project.org_id,
        name: filename,
        original_filename: filename,
        content_type: content_type,
        byte_size: byte_size(body),
        storage_key: "files/#{project.id}/#{Ecto.UUID.generate()}/#{filename}",
        content_hash: hash,
        ingest_status: Keyword.get(opts, :ingest_status, "ingested"),
        ingest_intent: Keyword.get(opts, :ingest_intent, "attempt")
      })

    if text = Keyword.get(opts, :text) do
      {:ok, _} = Files.upsert_extracted_text(file.id, text, nil)
    end

    file
  end

  defp create_file_with_bytes(project, body, opts) do
    filename = Keyword.fetch!(opts, :filename)

    {:ok, %{storage_key: storage_key, content_hash: hash, byte_size: real_size}} =
      Platform.Files.Storage.put({:binary, body}, project.id, filename: filename)

    {:ok, file} =
      Files.create_file(%{
        project_id: project.id,
        org_id: project.org_id,
        name: filename,
        original_filename: filename,
        content_type: Keyword.get(opts, :content_type, "video/quicktime"),
        byte_size: real_size,
        storage_key: storage_key,
        content_hash: hash,
        ingest_status: "not_attempted",
        ingest_intent: "human_only"
      })

    file
  end

  # Redirects `Platform.Files.Storage` writes to a per-test tmp dir so the
  # binary branch has real bytes to withhold.
  defp with_tmp_storage_root(_context) do
    root =
      Platform.TestTemp.path("platform-human-only-ctx-test")

    File.mkdir_p!(root)
    previous = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: Application.put_env(:platform, :chat_attachments_root, previous),
        else: Application.delete_env(:platform, :chat_attachments_root)
    end)

    :ok
  end
end
