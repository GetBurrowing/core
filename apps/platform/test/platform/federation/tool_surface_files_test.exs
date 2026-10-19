defmodule Platform.Federation.ToolSurfaceFilesTest do
  @moduledoc """
  Tests for the ADR-0042 Stage 4 files MCP surface — `file_list` and
  `file_get_text`. Authorization mirrors `memory_search`:

    * Agent pinned to a tenant org may only touch projects under that
      org. Sibling-org reads return an `unauthorized: …` envelope (NOT
      an empty list, so existence can't be probed).

    * Agent pinned to the root org (or no metadata pin at all) sees
      every tenant — root-equivalent.

  These tests stand the auth contract up end-to-end through
  `Platform.Federation.ToolSurface.execute/3`.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Federation.ToolSurface
  alias Platform.Files
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy

  # Stub memory provider — returns whatever the test injects via app env so
  # the file_search tests can assert behavior without standing up the real
  # embedding service. Mirrors the StubProvider pattern in
  # Platform.Org.Wiki.SearchTest.
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
    def delete(ids, config) do
      # file_delete scrub-assertion hook: tests that pass `notify_delete:
      # self()` to `install_memory_stub/2` receive the scrubbed ids.
      if pid = Keyword.get(config, :notify_delete), do: send(pid, {:memory_stub_delete, ids})
      {:ok, length(ids)}
    end

    @impl true
    def health(_c), do: :ok
  end

  defp install_memory_stub(results, extra \\ []) do
    prev = Application.get_env(:platform, :memory_service, [])

    Application.put_env(
      :platform,
      :memory_service,
      [provider: MemoryStub, search_results: results] ++ extra
    )

    on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)
    :ok
  end

  # ── Setup ──────────────────────────────────────────────────────────────

  setup do
    acme = ensure_root_org()
    # Two tenant orgs so we can exercise sibling-tenant isolation.
    globex = ensure_tenant_org("globex-files-#{System.unique_integer([:positive])}", acme)

    vandelay_ind =
      ensure_tenant_org("vandelay-ind-files-#{System.unique_integer([:positive])}", acme)

    {:ok, project_a} = Tasks.create_project(%{name: "ProjA #{u()}", org_id: globex.id})
    {:ok, project_b} = Tasks.create_project(%{name: "ProjB #{u()}", org_id: vandelay_ind.id})

    # Agent pinned to Globex — should see Globex projects, not Vandelay-ind.
    agent_globex = create_agent("globex-agent", %{"org_id" => globex.id})
    # Agent pinned to Vandelay-ind — sibling of agent_globex.
    agent_pt = create_agent("pt-agent", %{"org_id" => vandelay_ind.id})
    # Agent pinned to the root org — root-equivalent, sees every tenant.
    agent_root = create_agent("root-agent", %{"org_id" => acme.id})

    {:ok,
     %{
       acme: acme,
       globex: globex,
       vandelay_ind: vandelay_ind,
       project_a: project_a,
       project_b: project_b,
       agent_globex: agent_globex,
       agent_pt: agent_pt,
       agent_root: agent_root
     }}
  end

  defp u, do: System.unique_integer([:positive])

  defp ensure_root_org do
    case Repo.get_by(Tenancy.Org, slug: "acme") do
      nil ->
        {:ok, org} =
          %Tenancy.Org{}
          |> Tenancy.Org.changeset(%{slug: "acme", name: "Acme", parent_org_id: nil})
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
        name: String.capitalize(slug_prefix),
        status: "active",
        metadata: metadata
      })
      |> Repo.insert()

    agent
  end

  defp context_for(%Agent{id: id}), do: %{agent_id: id}

  defp create_file(project, opts \\ []) do
    filename = Keyword.get(opts, :filename, "doc-#{u()}.txt")
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
      pages = Keyword.get(opts, :pages)
      {:ok, _} = Files.upsert_extracted_text(file.id, text, pages)
    end

    file
  end

  # ── tool_definitions/0 — bundle registration ──────────────────────────

  describe "tool_definitions/0 — files bundle" do
    test "registers file_list + file_get_text + file_get_metadata + file_search + file_add + file_delete under the files bundle" do
      tools = ToolSurface.list_tools(["files"])
      names = MapSet.new(tools, & &1.name)

      assert "file_list" in names
      assert "file_get_text" in names
      assert "file_get_metadata" in names
      assert "file_search" in names
      assert "file_add" in names
      assert "file_delete" in names
      assert Enum.all?(tools, &(&1.bundle == "files"))
    end

    test "files tools carry the 6-component rubric" do
      ToolSurface.list_tools(["files"])
      |> Enum.each(fn tool ->
        for key <- [:name, :description, :parameters, :returns, :limitations, :when_to_use] do
          assert Map.has_key?(tool, key), "#{tool.name} missing key #{inspect(key)}"
        end
      end)
    end
  end

  # ── file_list ─────────────────────────────────────────────────────────

  describe "execute/3 file_list" do
    test "returns project files for an Globex-pinned agent reading an Globex project",
         %{agent_globex: agent, project_a: project} do
      f1 = create_file(project, filename: "alpha.txt", body: "alpha")
      f2 = create_file(project, filename: "beta.txt", body: "beta")

      assert {:ok, %{project_id: pid, count: 2, files: files}} =
               ToolSurface.execute("file_list", %{"project_id" => project.id}, context_for(agent))

      assert pid == project.id
      file_ids = MapSet.new(files, & &1.id)
      assert MapSet.member?(file_ids, f1.id)
      assert MapSet.member?(file_ids, f2.id)

      # Each row carries the canonical summary fields.
      [row | _] = files

      for key <- [
            :id,
            :name,
            :original_filename,
            :content_type,
            :byte_size,
            :ingest_status,
            :inserted_at
          ] do
        assert Map.has_key?(row, key), "file_summary missing key #{inspect(key)}"
      end
    end

    test "returns auth error for Globex agent reading Vandelay-ind project",
         %{agent_globex: agent, project_b: project} do
      _ = create_file(project, filename: "sibling.txt")

      assert {:error, %{error: msg, recoverable: false}} =
               ToolSurface.execute("file_list", %{"project_id" => project.id}, context_for(agent))

      assert msg =~ "unauthorized"
    end

    test "root-equivalent agent sees cross-tenant projects",
         %{agent_root: agent, project_a: a, project_b: b} do
      _ = create_file(a, filename: "in-globex.txt")
      _ = create_file(b, filename: "in-pt.txt")

      assert {:ok, %{count: 1}} =
               ToolSurface.execute("file_list", %{"project_id" => a.id}, context_for(agent))

      assert {:ok, %{count: 1}} =
               ToolSurface.execute("file_list", %{"project_id" => b.id}, context_for(agent))
    end

    test "honors content_type filter", %{agent_globex: agent, project_a: project} do
      _pdf = create_file(project, filename: "doc.pdf", content_type: "application/pdf")
      _txt = create_file(project, filename: "doc.txt", content_type: "text/plain")

      assert {:ok, %{files: files}} =
               ToolSurface.execute(
                 "file_list",
                 %{"project_id" => project.id, "content_type" => "application/pdf"},
                 context_for(agent)
               )

      assert length(files) == 1
      assert hd(files).content_type == "application/pdf"
    end

    test "unknown project_id returns :not_found", %{agent_root: agent} do
      bogus = Ecto.UUID.generate()

      assert {:error, %{code: :not_found, recoverable: false}} =
               ToolSurface.execute("file_list", %{"project_id" => bogus}, context_for(agent))
    end

    test "rejects explicit org_id mismatch from tenant-pinned agent",
         %{agent_globex: agent, project_a: project, vandelay_ind: pt} do
      _ = create_file(project)

      assert {:error, %{error: msg, recoverable: false}} =
               ToolSurface.execute(
                 "file_list",
                 %{"project_id" => project.id, "org_id" => pt.id},
                 context_for(agent)
               )

      assert msg =~ "unauthorized"
    end

    test "missing project_id returns recoverable arg error", %{agent_root: agent} do
      assert {:error, %{recoverable: true, error: msg}} =
               ToolSurface.execute("file_list", %{}, context_for(agent))

      assert msg =~ "project_id"
    end

    test "lists human-only files alongside readable ones, each carrying its own availability",
         %{agent_globex: agent, project_a: project} do
      readable = create_file(project, filename: "readable.txt", ingest_status: "ingested")

      withheld =
        create_file(project,
          filename: "human-only.mov",
          ingest_intent: "human_only",
          ingest_status: "not_attempted"
        )

      assert {:ok, %{count: 2, files: files}} =
               ToolSurface.execute("file_list", %{"project_id" => project.id}, context_for(agent))

      by_id = Map.new(files, &{&1.id, &1})

      # The human-only row is LISTED, not hidden. Hiding it is the rejected
      # design: an agent that cannot see the row tells the human no such
      # file exists moments after they uploaded it.
      assert Map.has_key?(by_id, withheld.id)
      assert Map.has_key?(by_id, readable.id)

      withheld_row = by_id[withheld.id]
      assert withheld_row.ingest_intent == "human_only"
      assert withheld_row.agent_content_available == false
      assert is_binary(withheld_row.agent_content_note)
      assert withheld_row.agent_content_note =~ "human-only"

      readable_row = by_id[readable.id]
      assert readable_row.ingest_intent == "attempt"
      assert readable_row.agent_content_available == true
      assert readable_row.agent_content_note == nil

      # Both booleans appear in one response, so a serialiser that
      # hardcodes either value fails this test rather than half-passing.
      assert MapSet.new(files, & &1.agent_content_available) ==
               MapSet.new([true, false])
    end

    test "pending, failed and human_only carry three DISTINCT notes",
         %{agent_globex: agent, project_a: project} do
      pending = create_file(project, filename: "pending.txt", ingest_status: "pending")
      failed = create_file(project, filename: "failed.txt", ingest_status: "failed")

      human_only =
        create_file(project,
          filename: "private.pdf",
          ingest_intent: "human_only",
          ingest_status: "not_attempted"
        )

      assert {:ok, %{count: 3, files: files}} =
               ToolSurface.execute("file_list", %{"project_id" => project.id}, context_for(agent))

      by_id = Map.new(files, &{&1.id, &1})

      for id <- [pending.id, failed.id, human_only.id] do
        assert by_id[id].agent_content_available == false
      end

      notes = Enum.map([pending.id, failed.id, human_only.id], &by_id[&1].agent_content_note)

      # Distinctness is the assertion that matters. A single generic
      # "content unavailable" note would satisfy every non-nil check above
      # while collapsing exactly the distinction this feature draws:
      # "wait a moment", "it broke", and "a person decided this".
      assert Enum.all?(notes, &is_binary/1)
      assert length(Enum.uniq(notes)) == 3
    end
  end

  # ── file_get_text ─────────────────────────────────────────────────────

  describe "execute/3 file_get_text" do
    test "returns the full body when no page arg",
         %{agent_globex: agent, project_a: project} do
      file = create_file(project, text: "alpha beta gamma", pages: nil)

      assert {:ok,
              %{
                file_id: id,
                text: "alpha beta gamma",
                total_pages: nil
              }} =
               ToolSurface.execute("file_get_text", %{"file_id" => file.id}, context_for(agent))

      assert id == file.id
    end

    test "returns just the requested page for a paginated file",
         %{agent_globex: agent, project_a: project} do
      pages = ["page one body", "page two body", "page three body"]
      file = create_file(project, text: Enum.join(pages, "\n\n"), pages: pages)

      assert {:ok, %{text: "page two body", page: 2, total_pages: 3}} =
               ToolSurface.execute(
                 "file_get_text",
                 %{"file_id" => file.id, "page" => 2},
                 context_for(agent)
               )
    end

    test "page out of range returns :page_out_of_range",
         %{agent_globex: agent, project_a: project} do
      pages = ["only one"]
      file = create_file(project, text: "only one", pages: pages)

      assert {:error, %{code: :page_out_of_range, recoverable: true}} =
               ToolSurface.execute(
                 "file_get_text",
                 %{"file_id" => file.id, "page" => 5},
                 context_for(agent)
               )
    end

    test "unknown file_id returns :not_found", %{agent_root: agent} do
      bogus = Ecto.UUID.generate()

      assert {:error, %{code: :not_found, recoverable: false}} =
               ToolSurface.execute("file_get_text", %{"file_id" => bogus}, context_for(agent))
    end

    test "file with no cached text returns :no_text_available",
         %{agent_globex: agent, project_a: project} do
      # Skip the upsert_extracted_text call — simulates a file that's
      # still ingesting / extraction failed.
      file = create_file(project, ingest_status: "pending")

      assert {:error, %{code: :no_text_available, recoverable: true}} =
               ToolSurface.execute("file_get_text", %{"file_id" => file.id}, context_for(agent))
    end

    test "returns auth error when reading a sibling-tenant file",
         %{agent_globex: agent, project_b: project} do
      file = create_file(project, text: "sibling tenant body")

      assert {:error, %{error: msg, recoverable: false}} =
               ToolSurface.execute("file_get_text", %{"file_id" => file.id}, context_for(agent))

      assert msg =~ "unauthorized"
    end

    test "root agent reads cross-tenant file", %{agent_root: agent, project_b: project} do
      file = create_file(project, text: "root sees it")

      assert {:ok, %{text: "root sees it"}} =
               ToolSurface.execute("file_get_text", %{"file_id" => file.id}, context_for(agent))
    end

    test ":no_text_available suggestion now mentions binary: true",
         %{agent_globex: agent, project_a: project} do
      file = create_file(project, ingest_status: "pending")

      assert {:error, %{code: :no_text_available, suggestion: suggestion}} =
               ToolSurface.execute("file_get_text", %{"file_id" => file.id}, context_for(agent))

      assert suggestion =~ "binary: true"
    end
  end

  # ── file_get_text (binary: true) ──────────────────────────────────────

  describe "execute/3 file_get_text — binary: true" do
    setup :with_tmp_storage_root

    test "returns base64 bytes for a small text file even when extracted text exists",
         %{agent_globex: agent, project_a: project} do
      body = "alpha-binary-body"
      file = create_file_with_bytes(project, body, filename: "alpha.txt")
      # Also seed the text cache to prove binary: true skips it.
      {:ok, _} = Files.upsert_extracted_text(file.id, "ignored extracted body", nil)

      assert {:ok,
              %{
                file_id: id,
                content_type: "text/plain",
                byte_size: size,
                data_base64: data_b64,
                original_filename: "alpha.txt"
              }} =
               ToolSurface.execute(
                 "file_get_text",
                 %{"file_id" => file.id, "binary" => true},
                 context_for(agent)
               )

      assert id == file.id
      assert size == byte_size(body)
      assert Base.decode64!(data_b64) == body
    end

    test "returns raw bytes when no platform_file_texts row exists",
         %{agent_globex: agent, project_a: project} do
      # A binary blob the extractor wouldn't index — no text upsert.
      body = <<0x50, 0x4B, 0x03, 0x04, "fake-zip-bytes">>

      file =
        create_file_with_bytes(project, body,
          filename: "bundle.zip",
          content_type: "application/zip"
        )

      refute Files.fetch_extracted_text(file.id)

      assert {:ok,
              %{
                file_id: id,
                content_type: "application/zip",
                data_base64: data_b64
              }} =
               ToolSurface.execute(
                 "file_get_text",
                 %{"file_id" => file.id, "binary" => true},
                 context_for(agent)
               )

      assert id == file.id
      assert Base.decode64!(data_b64) == body
    end

    test "rejects oversize file with :too_large", %{agent_globex: agent, project_a: project} do
      # Synthesize a 26 MB row WITHOUT writing 26 MB of bytes — the size
      # check runs against `file.byte_size` before the storage read, so
      # we can lie about the on-disk size and still exercise the cap.
      file =
        create_file_with_bytes(project, "tiny-on-disk",
          filename: "fake-big.bin",
          content_type: "application/octet-stream",
          byte_size_override: 26 * 1024 * 1024
        )

      assert {:error, %{code: :too_large, recoverable: false, limit: limit}} =
               ToolSurface.execute(
                 "file_get_text",
                 %{"file_id" => file.id, "binary" => true},
                 context_for(agent)
               )

      assert limit == 25 * 1024 * 1024
    end

    test "binary: true with sibling-tenant file returns unauthorized",
         %{agent_globex: agent, project_b: project} do
      file = create_file_with_bytes(project, "tenant-isolated", filename: "isolated.bin")

      assert {:error, %{error: msg, recoverable: false}} =
               ToolSurface.execute(
                 "file_get_text",
                 %{"file_id" => file.id, "binary" => true},
                 context_for(agent)
               )

      assert msg =~ "unauthorized"
    end

    test "binary: true with unknown file_id returns :not_found", %{agent_root: agent} do
      bogus = Ecto.UUID.generate()

      assert {:error, %{code: :not_found}} =
               ToolSurface.execute(
                 "file_get_text",
                 %{"file_id" => bogus, "binary" => true},
                 context_for(agent)
               )
    end
  end

  # Creates a file row AND persists real bytes through Storage.put so
  # binary: true can stream them back. Distinct from `create_file/2`
  # which fabricates a storage_key without touching the adapter — fine
  # for text-cache tests but useless when we actually need bytes.
  defp create_file_with_bytes(project, body, opts) do
    filename = Keyword.fetch!(opts, :filename)
    content_type = Keyword.get(opts, :content_type, "text/plain")

    {:ok, %{storage_key: storage_key, content_hash: hash, byte_size: real_size}} =
      Platform.Files.Storage.put({:binary, body}, project.id, filename: filename)

    {:ok, file} =
      Files.create_file(%{
        project_id: project.id,
        org_id: project.org_id,
        name: filename,
        original_filename: filename,
        content_type: content_type,
        byte_size: Keyword.get(opts, :byte_size_override, real_size),
        storage_key: storage_key,
        content_hash: hash,
        ingest_status: Keyword.get(opts, :ingest_status, "ingested"),
        ingest_intent: Keyword.get(opts, :ingest_intent, "attempt")
      })

    file
  end

  # ── human_only gate (task 019fd033 stage 3) ───────────────────────────
  #
  # These fixtures deliberately KEEP a `platform_file_texts` row on a
  # human_only file. `Files.withdraw_from_agent_context/1` deletes that
  # row, so a fixture without one would exercise the delete, not the
  # gate — and the gate would pass whether or not it exists. The two
  # barriers are independent and each needs its own proof.

  describe "execute/3 file_get_text — human_only gate" do
    test "refuses the extracted text of a human_only file that still HAS a text row",
         %{agent_globex: agent, project_a: project} do
      body = "confidential settlement terms paragraph"

      file =
        create_file(project, filename: "hr-note.txt", text: body, ingest_intent: "human_only")

      # Positive control: the body IS in the store the tool reads from,
      # so the refusal below is the gate refusing, not an empty table.
      assert %Platform.Files.Text{text: ^body} = Files.fetch_extracted_text(file.id)

      assert {:error, %{code: :human_only, recoverable: false} = err} =
               ToolSurface.execute("file_get_text", %{"file_id" => file.id}, context_for(agent))

      # Assert the specific fields, not `=~` over the whole envelope —
      # a substring can match from an unrelated field.
      refute err.error =~ body
      refute err.suggestion =~ body
      refute Map.has_key?(err, :text)
    end

    test "an otherwise-identical attempt-intent file DOES return the body",
         %{agent_globex: agent, project_a: project} do
      # Control for the test above: same shape, intent flipped. Without
      # this, a refusal could come from any unrelated fixture defect.
      body = "confidential settlement terms paragraph"
      file = create_file(project, filename: "hr-note-ok.txt", text: body)

      assert {:ok, %{text: ^body}} =
               ToolSurface.execute("file_get_text", %{"file_id" => file.id}, context_for(agent))
    end

    test "the page branch is gated too", %{agent_globex: agent, project_a: project} do
      pages = ["page one secret", "page two secret"]

      file =
        create_file(project,
          filename: "paged.pdf",
          content_type: "application/pdf",
          text: Enum.join(pages, "\n\n"),
          pages: pages,
          ingest_intent: "human_only"
        )

      assert {:error, %{code: :human_only}} =
               ToolSurface.execute(
                 "file_get_text",
                 %{"file_id" => file.id, "page" => 2},
                 context_for(agent)
               )
    end

    # NOT TESTED HERE, deliberately: "an unrecognised intent raises
    # rather than serving the body". The gate has no catch-all clause,
    # so it would — but the state is unrepresentable. A
    # `Repo.update_all` setting `ingest_intent: "sideways"` is rejected
    # by the `platform_files_ingest_intent_check` DB constraint, so any
    # such test would be killed by the constraint before reaching an
    # assertion, and would pass for a reason that has nothing to do with
    # the code under test. The DB is the stronger barrier; the missing
    # catch-all is belt-and-braces behind it.
  end

  # ── binary: true is gated too (task 019fd033 stage 2, member 3) ───────
  #
  # An earlier revision left `binary: true` OPEN, reasoning that raw
  # bytes are the "human audience" path. They are not: file_get_text is
  # the AGENT surface — a human downloads through the Files UI. Serving
  # byte-identical content to the same caller we just refused the
  # extracted text is a one-argument bypass, not a policy. Both branches
  # gate.
  describe "execute/3 file_get_text — human_only gates the binary branch" do
    setup :with_tmp_storage_root

    test "binary: true refuses a human_only row AND returns no bytes at all",
         %{agent_globex: agent, project_a: project} do
      body = "human-audience-bytes"

      file =
        create_file_with_bytes(project, body,
          filename: "human-only.txt",
          ingest_intent: "human_only"
        )

      {:ok, _} = Files.upsert_extracted_text(file.id, "extracted body", nil)

      # Same fixture, same agent, both branches: neither yields content.
      assert {:error, %{code: :human_only, recoverable: false}} =
               ToolSurface.execute("file_get_text", %{"file_id" => file.id}, context_for(agent))

      assert {:error, %{code: :human_only, recoverable: false} = err} =
               ToolSurface.execute(
                 "file_get_text",
                 %{"file_id" => file.id, "binary" => true},
                 context_for(agent)
               )

      # Key ABSENCE, not just an error tuple: a payload that both errors
      # and carries the bytes is the exact bug, and `{:error, _}` alone
      # cannot see it.
      refute Map.has_key?(err, :data_base64)
      refute err.error =~ body
      refute err.suggestion =~ body
      # And the bytes are not smuggled under some other key.
      refute inspect(err) =~ Base.encode64(body)
    end

    test "positive control: an attempt-intent file still serves BOTH text and bytes",
         %{agent_globex: agent, project_a: project} do
      # Without this, a gate that broke every read would pass every
      # refutation above.
      body = "readable-both-ways"

      file =
        create_file_with_bytes(project, body,
          filename: "readable.txt",
          ingest_intent: "attempt"
        )

      {:ok, _} = Files.upsert_extracted_text(file.id, "extracted readable body", nil)

      assert {:ok, %{text: "extracted readable body"}} =
               ToolSurface.execute("file_get_text", %{"file_id" => file.id}, context_for(agent))

      assert {:ok, %{data_base64: data_b64}} =
               ToolSurface.execute(
                 "file_get_text",
                 %{"file_id" => file.id, "binary" => true},
                 context_for(agent)
               )

      assert Base.decode64!(data_b64) == body
    end

    # Gate placement, not gate existence. If the intent check ran BEFORE
    # authorize_file_access/2, a sibling-org caller could tell
    # `:human_only` (file exists) from `unauthorized` (nothing said) and
    # use file_get_text as an existence oracle. Both branches pinned.
    test "a sibling-org caller gets unauthorized, never :human_only",
         %{agent_globex: agent, project_b: project} do
      file =
        create_file_with_bytes(project, "sibling-org-secret",
          filename: "sibling-human-only.txt",
          ingest_intent: "human_only"
        )

      for args <- [%{"file_id" => file.id}, %{"file_id" => file.id, "binary" => true}] do
        assert {:error, %{error: msg} = err} =
                 ToolSurface.execute("file_get_text", args, context_for(agent))

        assert msg =~ "unauthorized"
        refute Map.get(err, :code) == :human_only
      end
    end
  end

  # ── file_get_metadata ─────────────────────────────────────────────────

  describe "execute/3 file_get_metadata" do
    test "returns the canonical metadata shape for a same-org agent",
         %{agent_globex: agent, project_a: project} do
      file =
        create_file(project,
          filename: "metadata-doc.pdf",
          content_type: "application/pdf",
          body: "pdf-body"
        )

      assert {:ok, row} =
               ToolSurface.execute(
                 "file_get_metadata",
                 %{"file_id" => file.id},
                 context_for(agent)
               )

      # Required public fields are present.
      for key <- [
            :file_id,
            :project_id,
            :org_id,
            :name,
            :original_filename,
            :content_type,
            :byte_size,
            :content_hash,
            :ingest_status,
            :uploaded_by_user_id,
            :inserted_at,
            :updated_at
          ] do
        assert Map.has_key?(row, key), "file_metadata missing key #{inspect(key)}"
      end

      # storage_key is an internal handle — must never leak.
      refute Map.has_key?(row, :storage_key)

      assert row.file_id == file.id
      assert row.project_id == project.id
      assert row.org_id == project.org_id
      assert row.original_filename == "metadata-doc.pdf"
      assert row.content_type == "application/pdf"
      assert row.byte_size == byte_size("pdf-body")
      assert row.ingest_status == "ingested"
      assert row.ingest_intent == "attempt"
      assert row.agent_content_available == true
      assert row.agent_content_note == nil
    end

    test "a human-only file still returns metadata, marked unreadable with an explanation",
         %{agent_globex: agent, project_a: project} do
      file =
        create_file(project,
          filename: "board-deck.key",
          ingest_intent: "human_only",
          ingest_status: "not_attempted"
        )

      assert {:ok, row} =
               ToolSurface.execute(
                 "file_get_metadata",
                 %{"file_id" => file.id},
                 context_for(agent)
               )

      assert row.file_id == file.id
      assert row.original_filename == "board-deck.key"
      assert row.ingest_intent == "human_only"
      assert row.ingest_status == "not_attempted"
      assert row.agent_content_available == false
      assert row.agent_content_note =~ "human-only"
      assert row.agent_content_note =~ "ask them"
    end

    test "pending and failed metadata rows report distinct unavailability notes",
         %{agent_globex: agent, project_a: project} do
      pending = create_file(project, filename: "wip.txt", ingest_status: "pending")
      failed = create_file(project, filename: "broken.txt", ingest_status: "failed")

      assert {:ok, pending_row} =
               ToolSurface.execute(
                 "file_get_metadata",
                 %{"file_id" => pending.id},
                 context_for(agent)
               )

      assert {:ok, failed_row} =
               ToolSurface.execute(
                 "file_get_metadata",
                 %{"file_id" => failed.id},
                 context_for(agent)
               )

      assert pending_row.agent_content_available == false
      assert failed_row.agent_content_available == false
      assert pending_row.agent_content_note != failed_row.agent_content_note
    end

    test "unknown file_id returns :not_found", %{agent_root: agent} do
      bogus = Ecto.UUID.generate()

      assert {:error, %{code: :not_found, recoverable: false, error: msg}} =
               ToolSurface.execute(
                 "file_get_metadata",
                 %{"file_id" => bogus},
                 context_for(agent)
               )

      assert msg =~ "file_get_metadata"
    end

    test "missing file_id returns recoverable arg error", %{agent_root: agent} do
      assert {:error, %{recoverable: true, error: msg}} =
               ToolSurface.execute("file_get_metadata", %{}, context_for(agent))

      assert msg =~ "file_id"
    end

    test "tenant-pinned agent reading a sibling-org file gets unauthorized envelope",
         %{agent_globex: agent, project_b: project} do
      file = create_file(project, filename: "sibling-meta.txt")

      assert {:error, %{error: msg, recoverable: false}} =
               ToolSurface.execute(
                 "file_get_metadata",
                 %{"file_id" => file.id},
                 context_for(agent)
               )

      assert msg =~ "unauthorized"
    end

    test "root-equivalent agent reads cross-tenant file metadata",
         %{agent_root: agent, project_b: project} do
      file = create_file(project, filename: "cross-tenant.txt")

      assert {:ok, %{file_id: id, project_id: pid}} =
               ToolSurface.execute(
                 "file_get_metadata",
                 %{"file_id" => file.id},
                 context_for(agent)
               )

      assert id == file.id
      assert pid == project.id
    end

    test "file_id of a non-string type returns recoverable arg error",
         %{agent_root: agent} do
      assert {:error, %{recoverable: true, error: msg}} =
               ToolSurface.execute(
                 "file_get_metadata",
                 %{"file_id" => 12_345},
                 context_for(agent)
               )

      assert msg =~ "file_id"
    end
  end

  # ── file_search ───────────────────────────────────────────────────────

  describe "execute/3 file_search" do
    test "drops a human_only file that IS still present in the index",
         %{agent_globex: agent, project_a: project} do
      visible =
        create_file(project, filename: "public.txt", text: "public rate-limit cap is 100 rps")

      withheld =
        create_file(project,
          filename: "private.txt",
          text: "private rate-limit cap is 5 rps",
          ingest_intent: "human_only"
        )

      # The stub returns BOTH — i.e. the vector-index scrub is modelled
      # as having failed / not yet run. Without that the exclusion below
      # would be true by construction.
      install_memory_stub([
        %{entry_id: visible.id, score: 0.91},
        %{entry_id: withheld.id, score: 0.99}
      ])

      assert {:ok, %{count: 1, hits: hits}} =
               ToolSurface.execute(
                 "file_search",
                 %{"project_id" => project.id, "query" => "rate-limit cap"},
                 context_for(agent)
               )

      assert Enum.map(hits, & &1.file_id) == [visible.id]
      # Both sides: the hit is gone AND its body did not leak as a
      # snippet on some other hit.
      refute Enum.any?(hits, fn h -> h.snippet =~ "5 rps" end)
      # Positive control — the withheld row's text really is still there
      # for the snippet renderer to have found, had it not been gated.
      assert %Platform.Files.Text{} = Files.fetch_extracted_text(withheld.id)
    end

    # The steady state (created human_only, never extracted) is covered
    # above. THIS test covers the TRANSITION, which is where the leak
    # lives: a file ingested as "attempt" has a `platform_file_texts`
    # row and an index entry, and flipping it to human_only later must
    # take both away AND stop being returned.
    test "an ingested file flipped to human_only drops out and loses its cached text",
         %{agent_globex: agent, project_a: project} do
      kept =
        create_file(project, filename: "kept.txt", text: "kept rate-limit cap is 100 rps")

      flipped =
        create_file(project, filename: "flipped.txt", text: "secret rate-limit cap is 5 rps")

      # Pre-flip: the body really was cached and readable.
      assert %Platform.Files.Text{} = Files.fetch_extracted_text(flipped.id)

      assert {:ok, flipped} = Files.withdraw_from_agent_context(flipped)
      assert flipped.ingest_intent == "human_only"

      # Scrub-on-flip: the cached row went with the transaction.
      assert is_nil(Files.fetch_extracted_text(flipped.id))

      # Model the index scrub as having failed — the stub still returns
      # the withdrawn id. Without this the exclusion is true by
      # construction.
      install_memory_stub([
        %{entry_id: kept.id, score: 0.91},
        %{entry_id: flipped.id, score: 0.99}
      ])

      # Measured, not assumed: the withdrawn id IS in what the Memory
      # layer hands the dispatch, so a passing refutation below is the
      # read-time gate firing, not an empty corpus.
      assert {:ok, raw} =
               Platform.Memory.search("rate-limit cap",
                 project_id: project.id,
                 org_id: project.org_id,
                 memory_type: "document",
                 limit: 20
               )

      assert flipped.id in Enum.map(raw, & &1.entry_id)

      assert {:ok, %{count: 1, hits: hits}} =
               ToolSurface.execute(
                 "file_search",
                 %{"project_id" => project.id, "query" => "rate-limit cap"},
                 context_for(agent)
               )

      # Positive control in the same test: the un-flipped sibling still
      # hits, so zero hits for the flipped file is a decision.
      assert Enum.map(hits, & &1.file_id) == [kept.id]
      assert hd(hits).snippet =~ "100 rps"
      refute Enum.any?(hits, fn h -> h.snippet && h.snippet =~ "5 rps" end)
    end

    test "returns hits with snippets sourced from cached extracted text",
         %{agent_globex: agent, project_a: project} do
      f1 = create_file(project, filename: "alpha.txt", text: "alpha rate-limit cap is 100 rps")
      _f2 = create_file(project, filename: "beta.txt", text: "beta unrelated body")
      f3 = create_file(project, filename: "gamma.txt", text: "gamma rate-limit cap doc")

      # Memory provider returns 2 hits — f1 (highest score) and f3.
      install_memory_stub([
        %{entry_id: f1.id, score: 0.91},
        %{entry_id: f3.id, score: 0.74}
      ])

      assert {:ok, %{project_id: pid, count: 2, hits: hits}} =
               ToolSurface.execute(
                 "file_search",
                 %{"project_id" => project.id, "query" => "rate-limit cap"},
                 context_for(agent)
               )

      assert pid == project.id
      # f2 not in returned hits — only the two the memory stub returned.
      assert Enum.map(hits, & &1.file_id) == [f1.id, f3.id]

      [first, second] = hits

      for key <- [:file_id, :name, :original_filename, :content_type, :snippet, :score] do
        assert Map.has_key?(first, key), "file_search hit missing key #{inspect(key)}"
      end

      assert first.score == 0.91
      assert first.snippet =~ "rate-limit cap"
      assert second.snippet =~ "rate-limit cap"
      assert first.original_filename == "alpha.txt"

      # f2's body shouldn't be in any returned snippet.
      refute Enum.any?(hits, fn h -> h.snippet =~ "unrelated" end)
    end

    test "returns empty hits list (NOT :not_found) when memory returns nothing",
         %{agent_globex: agent, project_a: project} do
      _f = create_file(project, text: "anything")
      install_memory_stub([])

      assert {:ok, %{project_id: pid, count: 0, hits: []}} =
               ToolSurface.execute(
                 "file_search",
                 %{"project_id" => project.id, "query" => "nothing matches"},
                 context_for(agent)
               )

      assert pid == project.id
    end

    test "drops hits whose underlying file row has been deleted",
         %{agent_globex: agent, project_a: project} do
      f1 = create_file(project, filename: "kept.txt", text: "kept body")
      stale_id = Ecto.UUID.generate()

      install_memory_stub([
        %{entry_id: stale_id, score: 0.99},
        %{entry_id: f1.id, score: 0.5}
      ])

      assert {:ok, %{count: 1, hits: [hit]}} =
               ToolSurface.execute(
                 "file_search",
                 %{"project_id" => project.id, "query" => "kept"},
                 context_for(agent)
               )

      assert hit.file_id == f1.id
    end

    test "drops hits whose file lives in a different project (defense-in-depth)",
         %{agent_root: agent, project_a: a, project_b: b} do
      _in_a = create_file(a, filename: "in-a.txt", text: "in-a body")
      in_b = create_file(b, filename: "in-b.txt", text: "in-b body")

      # Memory stub leaks a cross-project id — the dispatch must drop it.
      install_memory_stub([%{entry_id: in_b.id, score: 0.8}])

      assert {:ok, %{project_id: pid, count: 0, hits: []}} =
               ToolSurface.execute(
                 "file_search",
                 %{"project_id" => a.id, "query" => "anything"},
                 context_for(agent)
               )

      assert pid == a.id
    end

    test "returns auth error for Globex agent searching Vandelay-ind project",
         %{agent_globex: agent, project_b: project} do
      _ = create_file(project, text: "sibling-body")
      install_memory_stub([])

      assert {:error, %{error: msg, recoverable: false}} =
               ToolSurface.execute(
                 "file_search",
                 %{"project_id" => project.id, "query" => "anything"},
                 context_for(agent)
               )

      assert msg =~ "unauthorized"
    end

    test "rejects explicit org_id mismatch from tenant-pinned agent",
         %{agent_globex: agent, project_a: project, vandelay_ind: pt} do
      _ = create_file(project, text: "body")
      install_memory_stub([])

      assert {:error, %{error: msg, recoverable: false}} =
               ToolSurface.execute(
                 "file_search",
                 %{"project_id" => project.id, "org_id" => pt.id, "query" => "x"},
                 context_for(agent)
               )

      assert msg =~ "unauthorized"
    end

    test "unknown project_id returns :not_found", %{agent_root: agent} do
      bogus = Ecto.UUID.generate()
      install_memory_stub([])

      assert {:error, %{code: :not_found, recoverable: false}} =
               ToolSurface.execute(
                 "file_search",
                 %{"project_id" => bogus, "query" => "anything"},
                 context_for(agent)
               )
    end

    test "missing query returns recoverable arg error",
         %{agent_globex: agent, project_a: project} do
      assert {:error, %{recoverable: true, error: msg}} =
               ToolSurface.execute(
                 "file_search",
                 %{"project_id" => project.id},
                 context_for(agent)
               )

      assert msg =~ "query"
    end

    test "missing project_id returns recoverable arg error", %{agent_root: agent} do
      assert {:error, %{recoverable: true, error: msg}} =
               ToolSurface.execute("file_search", %{"query" => "anything"}, context_for(agent))

      assert msg =~ "project_id"
    end

    test "honors the limit argument when forwarding to Memory",
         %{agent_globex: agent, project_a: project} do
      files =
        for i <- 1..5 do
          create_file(project, filename: "f#{i}.txt", text: "body #{i}")
        end

      # Stub returns 5 — caller asks for 3 — Memory provider would have
      # capped to 3, but our stub ignores opts. Assert that at least the
      # dispatch wires limit through without erroring and returns all 5
      # when the stub doesn't honor the cap (the cap is enforced by the
      # real provider; this test only proves the wiring doesn't blow up).
      install_memory_stub(Enum.map(files, &%{entry_id: &1.id, score: 0.5}))

      assert {:ok, %{count: 5}} =
               ToolSurface.execute(
                 "file_search",
                 %{"project_id" => project.id, "query" => "body", "limit" => 3},
                 context_for(agent)
               )
    end

    test "surfaces a recoverable error envelope when Memory.search errors",
         %{agent_globex: agent, project_a: project} do
      install_memory_stub({:error, :memory_service_down})

      assert {:error, %{code: :memory_service_error, recoverable: true, error: msg}} =
               ToolSurface.execute(
                 "file_search",
                 %{"project_id" => project.id, "query" => "anything"},
                 context_for(agent)
               )

      assert msg =~ "memory service"
    end

    test "snippet is nil when the file has no cached extracted text",
         %{agent_globex: agent, project_a: project} do
      file = create_file(project, ingest_status: "pending")
      install_memory_stub([%{entry_id: file.id, score: 0.6}])

      assert {:ok, %{count: 1, hits: [hit]}} =
               ToolSurface.execute(
                 "file_search",
                 %{"project_id" => project.id, "query" => "anything"},
                 context_for(agent)
               )

      assert hit.file_id == file.id
      assert is_nil(hit.snippet)
    end

    test "snippet truncates to 240 graphemes when body is longer",
         %{agent_globex: agent, project_a: project} do
      long_body = String.duplicate("x", 1_000)
      file = create_file(project, text: long_body)
      install_memory_stub([%{entry_id: file.id, score: 0.5}])

      assert {:ok, %{hits: [hit]}} =
               ToolSurface.execute(
                 "file_search",
                 %{"project_id" => project.id, "query" => "x"},
                 context_for(agent)
               )

      assert String.length(hit.snippet) == 240
    end
  end

  # ── the fourth path: the generic memory_search tool ───────────────────
  #
  # `memory_search` runs through `Platform.Org.Wiki.Search.search/2`,
  # which is a DIFFERENT dispatch from `file_search` and carries no
  # human_only gate. It is nevertheless not a leak, and by decision: the
  # semantic channel classifies each hit by its `memory_type` tag, and a
  # "document" tag — what the file ingester writes — classifies as
  # `:excluded` and is refused in `semantic_hit_to_channel/3` before
  # fusion. The refusal happens at classification, ahead of any id
  # lookup, so no file body can enter the result set. Measured here so
  # the refusal stays a refusal.
  #
  # A related fact, so nobody re-derives it: messages are never
  # semantically indexed, so the absence of a `semantic_corpus("message")`
  # clause is not a regression. Every ingest caller under
  # `lib/platform/` writes "page" or "journal" (the wiki indexer
  # payload), "task" (the task indexer), "document" (the file ingester),
  # or falls through the "daily" default in `Platform.Memory.normalize/1`
  # that untyped journal-entry structs take. Nothing under
  # `lib/platform/chat/` ingests at all. Semantic message search returned
  # nothing before the classification change and returns nothing after;
  # adding a clause for it would accomplish nothing without a message
  # indexer to feed it. `:message` in `@type corpus` is real, but it is
  # produced by the LEXICAL message channel, not this one.
  describe "memory_search (Wiki.Search) does not carry file bodies" do
    test "a document-typed hit for a file never reaches memory_search results",
         %{project_a: project} do
      file =
        create_file(project,
          filename: "leaky.txt",
          text: "canary body only reachable through the files surface"
        )

      install_memory_stub([
        %{entry_id: file.id, score: 0.99, memory_type: "document"}
      ])

      assert {:ok, %{results: results}} =
               Platform.Org.Wiki.Search.search("canary body",
                 project_id: project.id,
                 org_id: project.org_id,
                 limit: 20
               )

      refute Enum.any?(results, &(&1.id == file.id))
      refute Enum.any?(results, &(&1.content =~ "canary body"))
    end
  end

  # ── file_add ──────────────────────────────────────────────────────────

  # Redirects `Platform.Files.Storage` writes to a per-test tmp dir so the
  # inline branch's bytes are isolated from the shared per-run root.
  defp with_tmp_storage_root(_context) do
    root =
      Platform.TestTemp.path("platform-file-add-test")

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

  describe "execute/3 file_add (inline branch)" do
    setup :with_tmp_storage_root

    test "persists inline bytes, returns state: ready, fires async ingest",
         %{agent_globex: agent, project_a: project} do
      install_memory_stub([])
      body = "hello inline body #{u()}"
      data_b64 = Base.encode64(body)

      assert {:ok,
              %{
                id: file_id,
                project_id: pid,
                state: "ready",
                deduplicated: false,
                byte_size: size,
                content_hash: hash,
                content_type: "text/plain"
              }} =
               ToolSurface.execute(
                 "file_add",
                 %{
                   "project_id" => project.id,
                   "filename" => "inline-#{u()}.txt",
                   "content_type" => "text/plain",
                   "data_base64" => data_b64
                 },
                 context_for(agent)
               )

      assert pid == project.id
      assert size == byte_size(body)
      assert is_binary(hash) and hash != ""

      file = Files.get_file(file_id)
      assert file
      assert file.project_id == project.id
      assert file.org_id == project.org_id
      # Status starts at "pending" right after insert; the synchronous
      # Ingester.run/1 path (no TaskSupervisor in test env) may have
      # flipped it to "ingested" by the time we read.
      assert file.ingest_status in ["pending", "ingested"]
    end

    test "dedup branch returns the same id with deduplicated: true",
         %{agent_globex: agent, project_a: project} do
      install_memory_stub([])
      body = "dedup-body-#{u()}"
      data_b64 = Base.encode64(body)
      filename = "dedup-#{u()}.txt"

      assert {:ok, %{id: first_id, deduplicated: false}} =
               ToolSurface.execute(
                 "file_add",
                 %{
                   "project_id" => project.id,
                   "filename" => filename,
                   "content_type" => "text/plain",
                   "data_base64" => data_b64
                 },
                 context_for(agent)
               )

      # Synchronously flip the prior row to "ingested" so the dedup
      # find_ingested_sibling helper sees it. The first call's async
      # ingest path may not have completed in test env.
      {:ok, _} =
        first_id
        |> Files.get_file()
        |> Files.update_ingest_status("ingested")

      assert {:ok, %{id: second_id, deduplicated: true}} =
               ToolSurface.execute(
                 "file_add",
                 %{
                   "project_id" => project.id,
                   "filename" => "dedup-second-#{u()}.txt",
                   "content_type" => "text/plain",
                   "data_base64" => data_b64
                 },
                 context_for(agent)
               )

      assert second_id == first_id
    end

    test "rejects oversize inline payload with recoverable error",
         %{agent_globex: agent, project_a: project} do
      prev = Application.get_env(:platform, :inline_upload_max_bytes, 25 * 1024 * 1024)
      Application.put_env(:platform, :inline_upload_max_bytes, 16)
      on_exit(fn -> Application.put_env(:platform, :inline_upload_max_bytes, prev) end)

      data_b64 = Base.encode64(String.duplicate("x", 64))

      assert {:error, %{recoverable: true, error: msg}} =
               ToolSurface.execute(
                 "file_add",
                 %{
                   "project_id" => project.id,
                   "filename" => "big.txt",
                   "content_type" => "text/plain",
                   "data_base64" => data_b64
                 },
                 context_for(agent)
               )

      assert msg =~ "inline payload"
    end

    test "invalid base64 returns recoverable arg error",
         %{agent_globex: agent, project_a: project} do
      assert {:error, %{recoverable: true, error: msg}} =
               ToolSurface.execute(
                 "file_add",
                 %{
                   "project_id" => project.id,
                   "filename" => "bad.txt",
                   "content_type" => "text/plain",
                   "data_base64" => "this is not (((valid base64)))"
                 },
                 context_for(agent)
               )

      assert msg =~ "base64"
    end
  end

  describe "execute/3 file_add (presigned branch)" do
    setup :with_tmp_storage_root

    test "reserves a pending row and returns an upload_url",
         %{agent_globex: agent, project_a: project} do
      assert {:ok,
              %{
                id: file_id,
                project_id: pid,
                upload_url: url,
                expires_at: %DateTime{} = expires_at,
                max_bytes: max_bytes,
                state: "pending"
              }} =
               ToolSurface.execute(
                 "file_add",
                 %{
                   "project_id" => project.id,
                   "filename" => "big-pdf-#{u()}.pdf",
                   "content_type" => "application/pdf",
                   "byte_size" => 5 * 1024 * 1024
                 },
                 context_for(agent)
               )

      assert pid == project.id
      assert is_binary(url) and String.length(url) > 0
      assert max_bytes > 0
      assert DateTime.compare(expires_at, DateTime.utc_now()) == :gt

      file = Files.get_file(file_id)
      assert file
      assert file.ingest_status == "pending"
      assert is_nil(file.content_hash)
      assert file.byte_size == 5 * 1024 * 1024
      assert file.content_type == "application/pdf"
    end

    test "rejects oversize presigned byte_size",
         %{agent_globex: agent, project_a: project} do
      prev = Application.get_env(:platform, :upload_max_bytes, 500 * 1024 * 1024)
      Application.put_env(:platform, :upload_max_bytes, 1024)
      on_exit(fn -> Application.put_env(:platform, :upload_max_bytes, prev) end)

      assert {:error, %{recoverable: true, error: msg}} =
               ToolSurface.execute(
                 "file_add",
                 %{
                   "project_id" => project.id,
                   "filename" => "huge.bin",
                   "content_type" => "application/octet-stream",
                   "byte_size" => 4096
                 },
                 context_for(agent)
               )

      assert msg =~ "byte_size"
    end

    test "neither data_base64 nor byte_size returns recoverable arg error",
         %{agent_globex: agent, project_a: project} do
      assert {:error, %{recoverable: true, error: msg}} =
               ToolSurface.execute(
                 "file_add",
                 %{
                   "project_id" => project.id,
                   "filename" => "x.txt",
                   "content_type" => "text/plain"
                 },
                 context_for(agent)
               )

      assert msg =~ "data_base64"
      assert msg =~ "byte_size"
    end

    test "data_base64 takes precedence when both are passed",
         %{agent_globex: agent, project_a: project} do
      install_memory_stub([])
      body = "precedence-body-#{u()}"
      data_b64 = Base.encode64(body)

      assert {:ok, %{state: "ready", byte_size: size}} =
               ToolSurface.execute(
                 "file_add",
                 %{
                   "project_id" => project.id,
                   "filename" => "both.txt",
                   "content_type" => "text/plain",
                   "data_base64" => data_b64,
                   "byte_size" => 99_999_999
                 },
                 context_for(agent)
               )

      # Actual decoded length wins, not the declared byte_size.
      assert size == byte_size(body)
    end
  end

  describe "execute/3 file_add — authorization & arg validation" do
    setup :with_tmp_storage_root

    test "rejects Globex agent writing into a Vandelay-ind project",
         %{agent_globex: agent, project_b: project} do
      assert {:error, %{error: msg, recoverable: false}} =
               ToolSurface.execute(
                 "file_add",
                 %{
                   "project_id" => project.id,
                   "filename" => "x.txt",
                   "content_type" => "text/plain",
                   "data_base64" => Base.encode64("body")
                 },
                 context_for(agent)
               )

      assert msg =~ "unauthorized"
    end

    test "rejects explicit org_id mismatch from tenant-pinned agent",
         %{agent_globex: agent, project_a: project, vandelay_ind: pt} do
      assert {:error, %{error: msg, recoverable: false}} =
               ToolSurface.execute(
                 "file_add",
                 %{
                   "project_id" => project.id,
                   "org_id" => pt.id,
                   "filename" => "x.txt",
                   "content_type" => "text/plain",
                   "data_base64" => Base.encode64("body")
                 },
                 context_for(agent)
               )

      assert msg =~ "unauthorized"
    end

    test "unknown project_id returns :not_found", %{agent_root: agent} do
      bogus = Ecto.UUID.generate()

      assert {:error, %{code: :not_found, recoverable: false}} =
               ToolSurface.execute(
                 "file_add",
                 %{
                   "project_id" => bogus,
                   "filename" => "x.txt",
                   "content_type" => "text/plain",
                   "data_base64" => Base.encode64("body")
                 },
                 context_for(agent)
               )
    end

    test "missing project_id returns recoverable arg error",
         %{agent_root: agent} do
      assert {:error, %{recoverable: true, error: msg}} =
               ToolSurface.execute(
                 "file_add",
                 %{
                   "filename" => "x.txt",
                   "content_type" => "text/plain",
                   "data_base64" => Base.encode64("body")
                 },
                 context_for(agent)
               )

      assert msg =~ "project_id"
    end

    test "missing filename returns recoverable arg error",
         %{agent_root: agent, project_a: project} do
      assert {:error, %{recoverable: true, error: msg}} =
               ToolSurface.execute(
                 "file_add",
                 %{
                   "project_id" => project.id,
                   "content_type" => "text/plain",
                   "data_base64" => Base.encode64("body")
                 },
                 context_for(agent)
               )

      assert msg =~ "filename"
    end

    test "missing content_type returns recoverable arg error",
         %{agent_root: agent, project_a: project} do
      assert {:error, %{recoverable: true, error: msg}} =
               ToolSurface.execute(
                 "file_add",
                 %{
                   "project_id" => project.id,
                   "filename" => "x.txt",
                   "data_base64" => Base.encode64("body")
                 },
                 context_for(agent)
               )

      assert msg =~ "content_type"
    end
  end

  # ── file_delete ───────────────────────────────────────────────────────

  describe "execute/3 file_delete" do
    test "deletes the row and returns deleted: true",
         %{agent_globex: agent, project_a: project} do
      file = create_file(project, filename: "doomed.txt", body: "doomed body")
      assert Files.get_file(file.id), "precondition: file row exists"

      assert {:ok, %{file_id: id, deleted: true}} =
               ToolSurface.execute(
                 "file_delete",
                 %{"file_id" => file.id},
                 context_for(agent)
               )

      assert id == file.id
      refute Files.get_file(file.id), "row should be gone after delete"
    end

    test "idempotent re-delete returns :not_found (no crash)",
         %{agent_globex: agent, project_a: project} do
      file = create_file(project, filename: "twice.txt", body: "twice body")

      assert {:ok, %{deleted: true}} =
               ToolSurface.execute(
                 "file_delete",
                 %{"file_id" => file.id},
                 context_for(agent)
               )

      # Wrap the second call in a try/rescue to prove it returns an
      # envelope rather than crashing the caller process.
      result =
        try do
          ToolSurface.execute(
            "file_delete",
            %{"file_id" => file.id},
            context_for(agent)
          )
        rescue
          e -> {:raised, e}
        catch
          kind, payload -> {:caught, kind, payload}
        end

      assert {:error, %{code: :not_found, recoverable: false, error: msg}} = result
      assert msg =~ "file not found"
    end

    test "cross-org Globex agent deleting a Vandelay-ind file is rejected; row still exists",
         %{agent_globex: agent, project_b: project} do
      file = create_file(project, filename: "protect-only.txt", body: "off-limits")

      assert {:error, %{error: msg, recoverable: false}} =
               ToolSurface.execute(
                 "file_delete",
                 %{"file_id" => file.id},
                 context_for(agent)
               )

      assert msg =~ "unauthorized"
      assert Files.get_file(file.id), "row must NOT be deleted on auth failure"
    end

    test "rejects explicit org_id mismatch from tenant-pinned agent",
         %{agent_globex: agent, project_a: project, vandelay_ind: pt} do
      file = create_file(project, filename: "pinned.txt", body: "pinned")

      assert {:error, %{error: msg, recoverable: false}} =
               ToolSurface.execute(
                 "file_delete",
                 %{"file_id" => file.id, "org_id" => pt.id},
                 context_for(agent)
               )

      assert msg =~ "unauthorized"
      assert Files.get_file(file.id)
    end

    test "root-equivalent agent deletes a cross-tenant file",
         %{agent_root: agent, project_b: project} do
      file = create_file(project, filename: "root-reach.txt", body: "root-reach")

      assert {:ok, %{deleted: true}} =
               ToolSurface.execute(
                 "file_delete",
                 %{"file_id" => file.id},
                 context_for(agent)
               )

      refute Files.get_file(file.id)
    end

    test "unknown file_id returns :not_found", %{agent_root: agent} do
      bogus = Ecto.UUID.generate()

      assert {:error, %{code: :not_found, recoverable: false}} =
               ToolSurface.execute(
                 "file_delete",
                 %{"file_id" => bogus},
                 context_for(agent)
               )
    end

    test "missing file_id returns recoverable arg error", %{agent_root: agent} do
      assert {:error, %{recoverable: true, error: msg}} =
               ToolSurface.execute(
                 "file_delete",
                 %{},
                 context_for(agent)
               )

      assert msg =~ "file_id"
    end

    test "broadcasts {:file_deleted, file_id} on the project topic",
         %{agent_globex: agent, project_a: project} do
      file = create_file(project, filename: "broadcast.txt", body: "broadcast")
      :ok = Files.subscribe_project(project.id)

      assert {:ok, %{deleted: true}} =
               ToolSurface.execute(
                 "file_delete",
                 %{"file_id" => file.id},
                 context_for(agent)
               )

      assert_receive {:file_deleted, file_id}, 500
      assert file_id == file.id
    end

    # ── Soft-delete semantics (task 019f7cb0 stage 4 rewire) ────────────

    test "soft-deletes: row retained with deleted_at for the 30-day undo window",
         %{agent_globex: agent, project_a: project} do
      file = create_file(project, filename: "undoable.txt", body: "undoable")

      assert {:ok, %{deleted: true}} =
               ToolSurface.execute(
                 "file_delete",
                 %{"file_id" => file.id},
                 context_for(agent)
               )

      # Invisible on the normal read path…
      refute Files.get_file(file.id)

      # …but the row still exists for restore (the Purger owns permanent
      # removal after retention).
      assert %Files.File{deleted_at: %DateTime{}} =
               Files.get_file(file.id, include_deleted: true)
    end

    test "scrubs the AI search index under the file id",
         %{agent_globex: agent, project_a: project} do
      install_memory_stub([], notify_delete: self())
      file = create_file(project, filename: "indexed.txt", body: "indexed")

      assert {:ok, %{deleted: true}} =
               ToolSurface.execute(
                 "file_delete",
                 %{"file_id" => file.id},
                 context_for(agent)
               )

      assert_receive {:memory_stub_delete, ids}, 500
      assert ids == [file.id]
    end

    test "audit-logs the delete with the acting agent attributed",
         %{agent_globex: agent, project_a: project} do
      # Guarantee the telemetry→audit bridge is attached (same defensive
      # dance as Platform.Files.SoftDeleteTest — attach is idempotent-ish
      # via detach-first, and this module is async: false).
      Platform.Audit.TelemetryHandler.detach()
      Platform.Audit.TelemetryHandler.attach()

      on_exit(fn ->
        Platform.Audit.TelemetryHandler.detach()
        Platform.Audit.TelemetryHandler.attach()
      end)

      file = create_file(project, filename: "audited.txt", body: "audited")

      assert {:ok, %{deleted: true}} =
               ToolSurface.execute(
                 "file_delete",
                 %{"file_id" => file.id},
                 context_for(agent)
               )

      assert [event] = Platform.Audit.list(event_type: "platform.files.file_deleted")
      assert event.actor_id == agent.id
      assert event.actor_type == "agent"
      assert event.resource_type == "file"
      assert event.resource_id == file.id
    end

    test "refuses a caller with no resolvable agent identity; row untouched",
         %{project_a: project} do
      file = create_file(project, filename: "anon.txt", body: "anon")

      assert {:error, %{code: :unauthorized, recoverable: false}} =
               ToolSurface.execute("file_delete", %{"file_id" => file.id}, %{})

      assert Files.get_file(file.id), "row must survive an unattributable delete"
    end

    test "refuses a file in an archived project with :project_archived",
         %{agent_globex: agent, project_a: project} do
      file = create_file(project, filename: "frozen.txt", body: "frozen")

      project
      |> Tasks.Project.changeset(%{archived_at: DateTime.utc_now()})
      |> Repo.update!()

      assert {:error, %{code: :project_archived, recoverable: false}} =
               ToolSurface.execute(
                 "file_delete",
                 %{"file_id" => file.id},
                 context_for(agent)
               )

      assert Files.get_file(file.id), "row must survive a delete against an archived project"
    end
  end

  # ── Exhaustiveness guard (task 019fd318) ───────────────────────────────

  describe "agent_content_availability/1 is total over every storable pair" do
    # `agent_content_availability/1` deliberately has NO catch-all clause: an
    # unrecognised intent/status pair must raise rather than default to
    # readable, because a silent default would advertise content that was
    # deliberately withheld. That omission is only SAFE if the one pair it
    # does not match — `attempt` + `not_attempted` — is a pair the database
    # refuses to store. This guard ties the two together.
    #
    # Written as a cartesian-product enumeration rather than a hand-listed
    # set of pairs, so that adding a fifth `ingest_status` or a third
    # `ingest_intent` fails HERE, loudly, instead of quietly opening a new
    # unhandled hole in the helper.
    test "every pair the DB accepts has a clause; every pair it rejects names the coupling check",
         %{agent_globex: agent, project_a: project} do
      pairs =
        for intent <- Files.File.valid_ingest_intents(),
            status <- Files.File.valid_ingest_statuses(),
            do: {intent, status}

      # POSITIVE CONTROL on the enumeration itself — a product that came
      # back empty would make every assertion below vacuous.
      assert length(pairs) == 8

      {accepted, rejected} =
        Enum.split_with(pairs, fn {intent, status} ->
          match?({:ok, _}, insert_pair(project, intent, status))
        end)

      # Exactly one pair is unstorable, and it is the one the helper has no
      # clause for.
      assert rejected == [{"attempt", "not_attempted"}]
      assert length(accepted) == 7

      for {intent, status} <- rejected do
        assert {:error, %Ecto.Changeset{} = changeset} = insert_pair(project, intent, status)

        # Same discipline as the stage-3 probe: a rejection from ANY other
        # constraint would make this guard vacuous. Assert the name.
        assert [{:ingest_status, {_msg, opts}}] = changeset.errors

        assert Keyword.get(opts, :constraint_name) ==
                 "platform_files_not_attempted_requires_human_only_check"
      end

      for {intent, status} <- accepted do
        {:ok, file} = insert_pair(project, intent, status)

        result =
          ToolSurface.execute(
            "file_get_metadata",
            %{"file_id" => file.id},
            context_for(agent)
          )

        assert {:ok, row} = result,
               "file_get_metadata refused the storable pair #{intent}/#{status}: " <>
                 inspect(result)

        # The `{available, note}` shape, surfaced through the public entry
        # point. A FunctionClauseError inside the helper would have blown up
        # the execute/3 call above rather than reaching here.
        assert is_boolean(row.agent_content_available)
        assert is_nil(row.agent_content_note) or is_binary(row.agent_content_note)
        assert row.ingest_intent == intent
        assert row.ingest_status == status
      end
    end
  end

  # Persists a file row carrying exactly this intent/status pair through
  # `File.changeset/2`, returning the raw `{:ok, file} | {:error, changeset}`
  # so callers can classify the pair as storable or not.
  defp insert_pair(project, intent, status) do
    n = u()
    body = "pair-#{intent}-#{status}-#{n}"

    %Files.File{}
    |> Files.File.changeset(%{
      project_id: project.id,
      org_id: project.org_id,
      name: "pair-#{n}.txt",
      original_filename: "pair-#{n}.txt",
      content_type: "text/plain",
      byte_size: byte_size(body),
      storage_key: "files/#{project.id}/#{Ecto.UUID.generate()}/pair-#{n}.txt",
      content_hash: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
      ingest_intent: intent,
      ingest_status: status
    })
    |> Repo.insert()
  end
end
