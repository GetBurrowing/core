defmodule Platform.Agents.ConfigFiles.Backend.WorkspaceStore do
  @moduledoc """
  Native agents: the files core stores for the agent
  (`agent_workspace_files`, written to its work dir by the agent host on every
  start). The hash is over the stored bytes.

  DRIFT. If the agent edited a file on disk after the host wrote it, the host
  reports the key in `files_drifted`. A write to a drifted key is a conflict,
  and the conflict carries the DISK hash. It is accepted only when the caller's
  `expected_sha256` equals that disk hash: the owner has fetched the disk copy
  (`AgentHost.file_read/2`, Compare), applied their edit on top and saved. The
  save bumps the stored version, which is what puts the key in
  `NativeAgents.force_keys/1` at the next start.
  """
  @behaviour Platform.Agents.ConfigFiles.Backend

  alias Platform.AgentHost
  alias Platform.Agents.ConfigFiles.Redaction
  alias Platform.Agents.{MemoryContext, NativeAgents, WorkspaceFile}

  @doc "Lowercase hex SHA-256."
  def sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  @impl true
  def list(%{agent: agent}) do
    drifted = NativeAgents.drifted_keys(agent)

    {:ok,
     for %WorkspaceFile{file_key: key, content: content} <- NativeAgents.list_files(agent) do
       %{path: key, sha256: sha256(content), secret?: false, drifted?: key in drifted}
     end}
  end

  @impl true
  def read(%{agent: agent}, path) do
    case MemoryContext.get_workspace_file(agent.id, path) do
      %WorkspaceFile{content: content} -> {:ok, %{content: content, sha256: sha256(content)}}
      nil -> {:error, :not_found}
    end
  end

  @impl true
  def write(ctx, path, content, expected) do
    current = MemoryContext.get_workspace_file(ctx.agent.id, path)

    with :ok <- check_precondition(ctx, path, current, expected),
         {:ok, restored} <- Redaction.restore(path, content, current && current.content) do
      save(ctx, path, restored, current)
    end
  end

  @impl true
  def set_secret(ctx, path, pointer, value) do
    current = MemoryContext.get_workspace_file(ctx.agent.id, path)

    with :ok <- check_drift(ctx, path, current, :secret),
         {:ok, merged} <- Redaction.put_secret(path, current && current.content, pointer, value) do
      save(ctx, path, merged, current)
    end
  end

  # The agent host never removes a file from disk that is no longer stored,
  # so deleting the stored copy would leave the agent reading it: refused.
  @impl true
  def delete(_ctx, _path, _expected), do: {:error, :unsupported}

  # ── preconditions ──────────────────────────────────────────────────

  defp check_precondition(ctx, path, current, expected) do
    if path in NativeAgents.drifted_keys(ctx.agent) do
      check_drift(ctx, path, current, expected)
    else
      case {expected, current} do
        {nil, nil} ->
          :ok

        {nil, current} ->
          {:conflict, sha256(current.content)}

        {_, nil} ->
          {:conflict, nil}

        {exp, current} ->
          if sha256(current.content) == exp, do: :ok, else: {:conflict, sha256(current.content)}
      end
    end
  end

  defp check_drift(ctx, path, current, expected) do
    if path in NativeAgents.drifted_keys(ctx.agent) do
      case AgentHost.file_read(ctx.agent, path) do
        {:ok, %{sha256: disk}} -> if expected == disk, do: :ok, else: {:conflict, disk}
        {:error, :not_found} -> if expected == nil, do: :ok, else: {:conflict, nil}
        {:error, _} -> {:error, :agent_host_unavailable}
      end
    else
      if current, do: :ok, else: :ok
    end
  end

  defp save(ctx, path, content, current) do
    case NativeAgents.save_file(ctx.actor, ctx.agent, path, content, current && current.version) do
      {:ok, %WorkspaceFile{content: saved}} ->
        {:ok, sha256(saved)}

      {:error, reason} when reason in [:stale_workspace_file, :file_exists] ->
        fresh = MemoryContext.get_workspace_file(ctx.agent.id, path)
        {:conflict, fresh && sha256(fresh.content)}

      {:error, %Ecto.Changeset{}} ->
        {:error, :invalid}

      {:error, _} = error ->
        error
    end
  end
end
