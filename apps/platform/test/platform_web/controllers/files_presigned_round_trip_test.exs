defmodule PlatformWeb.FilesPresignedRoundTripTest do
  @moduledoc """
  End-to-end round trip for `file_add`'s presigned branch (task 01a091b7
  stage 3): the tool reserves a `platform_files` row and hands back an
  `upload_url`; the byte POST lands in
  `PlatformWeb.ChatAttachmentUploadController`, which falls through from
  `chat_attachments` to `platform_files` (stage 2) and finalizes via
  `Platform.Files.finalize_presigned_upload/2` (stage 1); async ingest
  then makes the file readable through `file_get_text` and searchable
  through `file_search`.

  Nothing here calls `finalize_presigned_upload/3` directly — the only
  link between the tool contract and the finalized row is the POST. The
  named mutation for this file is reverting the controller's
  `lookup_pending/1` fall-through: scenario (1) must then go red at the
  POST with 404.
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation.ToolSurface
  alias Platform.Files
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy

  # Records every provider ingest in the test process. `Platform.Memory.ingest/2`
  # merges the `:memory_service` env into the provider config, so the pid
  # rides along as `config[:test_pid]` — the Ingester runs in a
  # TaskSupervisor child, so `Process.get` would not reach us.
  defmodule RecordingMemoryStub do
    @behaviour Platform.Memory.Provider

    @impl true
    def ingest(entries, config) do
      case Keyword.get(config, :test_pid) do
        pid when is_pid(pid) -> send(pid, {:ingested, entries})
        _ -> :ok
      end

      {:ok, length(entries)}
    end

    @impl true
    def search(_query, _opts, config) do
      case Keyword.get(config, :search_results, []) do
        {:error, _} = err -> err
        list when is_list(list) -> {:ok, list}
      end
    end

    @impl true
    def delete(_ids, _config), do: {:ok, 0}

    @impl true
    def health(_), do: :ok
  end

  defp install_memory_stub(results) do
    prev = Application.get_env(:platform, :memory_service, [])

    Application.put_env(:platform, :memory_service,
      provider: RecordingMemoryStub,
      search_results: results,
      test_pid: self()
    )

    on_exit(fn -> Application.put_env(:platform, :memory_service, prev) end)
    :ok
  end

  defp with_tmp_storage_root(_) do
    root = Platform.TestTemp.path("platform-files-presigned-round-trip")
    File.mkdir_p!(root)
    previous = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: Application.put_env(:platform, :chat_attachments_root, previous),
        else: Application.delete_env(:platform, :chat_attachments_root)
    end)

    {:ok, %{storage_root: root}}
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

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  setup :with_tmp_storage_root

  setup do
    fabrikam = ensure_root_org()

    {:ok, org} =
      %Tenancy.Org{}
      |> Tenancy.Org.changeset(%{
        slug: "rt-files-#{u()}",
        name: "Round Trip",
        parent_org_id: fabrikam.id
      })
      |> Repo.insert()

    {:ok, project} = Tasks.create_project(%{name: "RT-#{u()}", org_id: org.id})
    agent = create_agent("rt-agent", %{"org_id" => org.id})

    {:ok, %{org: org, project: project, agent: agent}}
  end

  # file_add presigned branch -> POST the bytes at the returned upload_url.
  # Returns the reservation envelope and the finalized conn.
  defp reserve_and_post(conn, project, agent, filename, body) do
    assert {:ok, reservation} =
             ToolSurface.execute(
               "file_add",
               %{
                 "project_id" => project.id,
                 "filename" => filename,
                 "content_type" => "text/plain",
                 "byte_size" => byte_size(body)
               },
               context_for(agent)
             )

    assert reservation.state == "pending"
    assert "/chat/attachments/upload/" <> _ = reservation.upload_url

    conn =
      conn
      |> Plug.Conn.put_req_header("content-type", "text/plain")
      |> Plug.Conn.put_req_header("content-length", Integer.to_string(byte_size(body)))
      |> post(reservation.upload_url, body)

    {reservation, conn}
  end

  # Ingest is async (TaskSupervisor child). Wait for the recorded provider
  # ingest of THIS file, then for the row itself to read "ingested" — the
  # provider call precedes the status write, so the message alone is not
  # enough.
  defp await_ingested(file_id) do
    receive do
      {:ingested, entries} ->
        # `Platform.Memory.normalize/1` keys the entry by `:id` (the file id).
        if Enum.any?(entries, &(Map.get(&1, :id) == file_id)),
          do: :ok,
          else: await_ingested(file_id)
    after
      5_000 -> flunk("no provider ingest recorded for #{file_id} within 5s")
    end

    Enum.reduce_while(1..50, :timeout, fn _, _ ->
      case Files.get_file(file_id) do
        %{ingest_status: "ingested"} ->
          {:halt, :ok}

        _ ->
          Process.sleep(100)
          {:cont, :timeout}
      end
    end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("file #{file_id} never reached ingest_status ingested")
    end
  end

  test "(1) file_add presigned -> POST -> metadata, get_text, search all see the bytes",
       %{conn: conn, project: project, agent: agent} do
    install_memory_stub([])

    body = String.duplicate("presigned round trip #{u()} ", 64)
    n = byte_size(body)
    hash = sha256(body)

    {reservation, conn} = reserve_and_post(conn, project, agent, "round_trip-#{u()}.txt", body)
    file_id = reservation.id

    assert response = json_response(conn, 200)
    assert response["id"] == file_id
    assert response["state"] == "ready"
    assert response["deduplicated"] == false
    assert response["byte_size"] == n
    assert response["content_hash"] == hash

    assert {:ok, meta} =
             ToolSurface.execute("file_get_metadata", %{"file_id" => file_id}, context_for(agent))

    assert meta.file_id == file_id
    assert meta.byte_size == n
    assert meta.content_hash == hash
    refute Map.has_key?(meta, :storage_key)

    await_ingested(file_id)

    assert {:ok, %{file_id: ^file_id, text: text}} =
             ToolSurface.execute("file_get_text", %{"file_id" => file_id}, context_for(agent))

    assert text == body

    install_memory_stub([%{entry_id: file_id, score: 0.93}])

    assert {:ok, %{count: 1, hits: [hit]}} =
             ToolSurface.execute(
               "file_search",
               %{"project_id" => project.id, "query" => "presigned round trip"},
               context_for(agent)
             )

    assert hit.file_id == file_id
    assert hit.snippet =~ "presigned round trip"
  end

  test "(2) the same bytes reserved and POSTed twice dedup onto the first id and strand nothing",
       %{conn: conn, project: project, agent: agent} do
    install_memory_stub([])

    body = "dedup me #{u()}\n"

    {first, conn1} = reserve_and_post(conn, project, agent, "dup_a-#{u()}.txt", body)
    assert json_response(conn1, 200)["deduplicated"] == false
    await_ingested(first.id)

    {second, conn2} = reserve_and_post(build_conn(), project, agent, "dup_b-#{u()}.txt", body)
    assert second.id != first.id

    assert response = json_response(conn2, 200)
    assert response["state"] == "ready"
    assert response["deduplicated"] == true
    assert response["id"] == first.id
    assert response["content_hash"] == sha256(body)

    # The redundant reservation is gone, not left as a pending row.
    assert Files.list_files_for_project(project.id, ingest_status: "pending") == []
    assert is_nil(Files.get_file(second.id))
    assert [%{id: only_id}] = Files.list_files_for_project(project.id)
    assert only_id == first.id
  end

  test "(3) a chat attachment.upload_start + POST on the same controller still finalizes ready",
       %{conn: conn, agent: agent} do
    {:ok, space} =
      Chat.create_space(%{name: "RT chat", slug: "rt-chat-#{u()}", kind: "channel"})

    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: "RT",
        joined_at: DateTime.utc_now()
      })

    body = :crypto.strong_rand_bytes(1_024)

    assert {:ok, %{id: attachment_id, upload_url: upload_url}} =
             ToolSurface.execute(
               "attachment.upload_start",
               %{
                 "space_id" => space.id,
                 "filename" => "chat.bin",
                 "content_type" => "application/octet-stream",
                 "byte_size" => byte_size(body)
               },
               context_for(agent)
             )

    conn =
      conn
      |> Plug.Conn.put_req_header("content-type", "application/octet-stream")
      |> Plug.Conn.put_req_header("content-length", "1024")
      |> post(upload_url, body)

    # The chat envelope has never carried `state` — it is `%{id, url,
    # byte_size, content_hash, deduplicated}` (ToolHandlers.finalize_pending/2);
    # "ready" is the ROW state. Only the Files branch echoes `state: "ready"`.
    assert response = json_response(conn, 200)
    assert response["id"] == attachment_id
    refute Map.has_key?(response, "state")
    assert response["deduplicated"] == false
    assert response["byte_size"] == 1_024
    assert response["url"] == "/chat/attachments/#{attachment_id}"
    assert response["content_hash"] == sha256(body)
    assert Repo.get!(Chat.Attachment, attachment_id).state == "ready"
  end
end
