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

  # ── Setup ──────────────────────────────────────────────────────────────

  setup do
    fabrikam = ensure_root_org()
    # Two tenant orgs so we can exercise sibling-tenant isolation.
    sxi = ensure_tenant_org("sxi-files-#{System.unique_integer([:positive])}", fabrikam)

    wayne_tech =
      ensure_tenant_org("wayne-tech-files-#{System.unique_integer([:positive])}", fabrikam)

    {:ok, project_a} = Tasks.create_project(%{name: "ProjA #{u()}", org_id: sxi.id})
    {:ok, project_b} = Tasks.create_project(%{name: "ProjB #{u()}", org_id: wayne_tech.id})

    # Agent pinned to SXI — should see SXI projects, not Wayne-tech.
    agent_sxi = create_agent("sxi-agent", %{"org_id" => sxi.id})
    # Agent pinned to Wayne-tech — sibling of agent_sxi.
    agent_pt = create_agent("pt-agent", %{"org_id" => wayne_tech.id})
    # Agent pinned to the root org — root-equivalent, sees every tenant.
    agent_root = create_agent("root-agent", %{"org_id" => fabrikam.id})

    {:ok,
     %{
       fabrikam: fabrikam,
       sxi: sxi,
       wayne_tech: wayne_tech,
       project_a: project_a,
       project_b: project_b,
       agent_sxi: agent_sxi,
       agent_pt: agent_pt,
       agent_root: agent_root
     }}
  end

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
        ingest_status: Keyword.get(opts, :ingest_status, "ingested")
      })

    if text = Keyword.get(opts, :text) do
      pages = Keyword.get(opts, :pages)
      {:ok, _} = Files.upsert_extracted_text(file.id, text, pages)
    end

    file
  end

  # ── tool_definitions/0 — bundle registration ──────────────────────────

  describe "tool_definitions/0 — files bundle" do
    test "registers file_list + file_get_text under the files bundle" do
      tools = ToolSurface.list_tools(["files"])
      names = MapSet.new(tools, & &1.name)

      assert "file_list" in names
      assert "file_get_text" in names
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
    test "returns project files for an SXI-pinned agent reading an SXI project",
         %{agent_sxi: agent, project_a: project} do
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

    test "returns auth error for SXI agent reading Wayne-tech project",
         %{agent_sxi: agent, project_b: project} do
      _ = create_file(project, filename: "sibling.txt")

      assert {:error, %{error: msg, recoverable: false}} =
               ToolSurface.execute("file_list", %{"project_id" => project.id}, context_for(agent))

      assert msg =~ "unauthorized"
    end

    test "root-equivalent agent sees cross-tenant projects",
         %{agent_root: agent, project_a: a, project_b: b} do
      _ = create_file(a, filename: "in-sxi.txt")
      _ = create_file(b, filename: "in-pt.txt")

      assert {:ok, %{count: 1}} =
               ToolSurface.execute("file_list", %{"project_id" => a.id}, context_for(agent))

      assert {:ok, %{count: 1}} =
               ToolSurface.execute("file_list", %{"project_id" => b.id}, context_for(agent))
    end

    test "honors content_type filter", %{agent_sxi: agent, project_a: project} do
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
         %{agent_sxi: agent, project_a: project, wayne_tech: pt} do
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
  end

  # ── file_get_text ─────────────────────────────────────────────────────

  describe "execute/3 file_get_text" do
    test "returns the full body when no page arg",
         %{agent_sxi: agent, project_a: project} do
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
         %{agent_sxi: agent, project_a: project} do
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
         %{agent_sxi: agent, project_a: project} do
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
         %{agent_sxi: agent, project_a: project} do
      # Skip the upsert_extracted_text call — simulates a file that's
      # still ingesting / extraction failed.
      file = create_file(project, ingest_status: "pending")

      assert {:error, %{code: :no_text_available, recoverable: true}} =
               ToolSurface.execute("file_get_text", %{"file_id" => file.id}, context_for(agent))
    end

    test "returns auth error when reading a sibling-tenant file",
         %{agent_sxi: agent, project_b: project} do
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
  end
end
