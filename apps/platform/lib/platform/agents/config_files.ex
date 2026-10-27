defmodule Platform.Agents.ConfigFiles do
  @moduledoc """
  An agent's configuration files, read and written on its behalf
  (task 01a17b1c). The one door: the Configuration screen and anything else
  that edits `CLAUDE.md`, `.mcp.json`, `config.toml` and friends goes through
  here.

      list(actor, agent)                          {:ok, [%{path, sha256, secret?}]}
      read(actor, agent, path)                    {:ok, %{content, sha256, secret_names}}
      write(actor, agent, path, content, expected_sha256)
                                                  {:ok, sha256} | {:conflict, current_sha256} | {:error, reason}
      set_secret(actor, agent, path, pointer, value)
                                                  {:ok, sha256} | {:conflict, sha256} | {:error, reason}

  `Platform.Agents.ConfigFiles.Access` decides who may. The backend is picked from
  the agent: `Backend.WorkspaceStore` for a native agent, `Backend.Host` for a
  federated one (over `runtime_host:<id>`).

  GUARANTEES

    * A write carries `expected_sha256` (nil = create-only). A mismatch is a
      `:conflict`, never an overwrite.
    * A secret VALUE is never in a read, a list entry, an audit row or a log
      line. Reads pass through `Config.Redaction`, even when the host already
      redacted.
    * A secret file (`.env*`, credentials) cannot be written through `write/5`;
      `set_secret/5` is write-only.
    * Exactly one `Platform.Audit` row per write or `set_secret` attempt,
      including refusals and conflicts: event `config.write` or
      `config.secret_set`, metadata `agent_id`, `path`, `old_sha256`,
      `new_sha256`, `result`. Never content or a value.
  """

  require Logger

  alias Platform.Agents.Agent
  alias Platform.Agents.ConfigFiles.{Access, Redaction}
  alias Platform.Agents.ConfigFiles.Backend.{Host, WorkspaceStore}
  alias Platform.Agents.NativeAgents
  alias Platform.Audit

  @type result :: term()

  @spec list(term(), Agent.t()) :: {:ok, [map()]} | {:error, term()}
  def list(actor, agent) do
    with {:ok, ctx} <- Access.authorize(actor, agent),
         {:ok, entries} <- backend(ctx).list(ctx) do
      {:ok,
       entries
       |> Enum.filter(&NativeAgents.valid_file_key?(&1.path))
       |> Enum.map(&Map.put(&1, :secret?, secret?(ctx, &1.path)))
       |> Enum.sort_by(& &1.path)}
    end
  end

  @spec read(term(), Agent.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def read(actor, agent, path) do
    with {:ok, ctx} <- Access.authorize(actor, agent),
         :ok <- check_path(path),
         {:ok, %{content: content, sha256: sha}} <- backend(ctx).read(ctx, path) do
      {shown, names} = Redaction.apply(ctx.adapter, path, content)
      {:ok, %{content: shown, sha256: sha, secret_names: names}}
    end
  end

  @doc """
  The disk copy of a native agent's file, for Compare. Redacted like any read.
  """
  @spec read_disk(term(), Agent.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def read_disk(actor, agent, path) do
    with {:ok, %{backend: :workspace_store} = ctx} <- Access.authorize(actor, agent),
         :ok <- check_path(path),
         {:ok, %{content: content, sha256: sha}} <- Platform.AgentHost.file_read(agent, path) do
      {shown, names} = Redaction.apply(ctx.adapter, path, content)
      {:ok, %{content: shown, sha256: sha, secret_names: names}}
    else
      {:ok, _federated} -> {:error, :not_native}
      other -> other
    end
  end

  @spec write(term(), Agent.t(), String.t(), binary(), String.t() | nil) :: result()
  def write(actor, agent, path, content, expected_sha256) when is_binary(content) do
    attempt(actor, agent, "config.write", path, expected_sha256, fn ctx ->
      cond do
        Redaction.secret_path?(path) -> {:error, :secret_path}
        true -> backend(ctx).write(ctx, path, content, expected_sha256)
      end
    end)
  end

  @spec set_secret(term(), Agent.t(), String.t(), String.t(), String.t()) :: result()
  def set_secret(actor, agent, path, pointer, value) when is_binary(value) do
    attempt(actor, agent, "config.secret_set", path, nil, fn ctx ->
      backend(ctx).set_secret(ctx, path, pointer, value)
    end)
  end

  # ── internals ──────────────────────────────────────────────────────

  defp attempt(actor, agent, event, path, expected, fun) do
    {result, old_sha} =
      with {:ok, ctx} <- Access.authorize(actor, agent),
           :ok <- check_path(path) do
        {fun.(ctx), expected}
      else
        {:error, _} = error -> {error, expected}
      end

    audit(actor, agent, event, path, old_sha, result)
    result
  end

  defp check_path(path) do
    if NativeAgents.valid_file_key?(path), do: :ok, else: {:error, :invalid_path}
  end

  defp backend(%{backend: :workspace_store}), do: WorkspaceStore
  defp backend(%{backend: :host}), do: Host

  defp secret?(ctx, path) do
    Redaction.secret_path?(path) or Platform.Agents.Harness.path_tag(ctx.adapter, path) == :secret
  end

  defp audit(actor, agent, event, path, old_sha, result) do
    {outcome, new_sha, current_sha} =
      case result do
        {:ok, sha} -> {"ok", sha, nil}
        {:conflict, current} -> {"conflict", nil, current}
        {:error, reason} -> {"refused:" <> reason_name(reason), nil, nil}
      end

    attrs = %{
      event_type: event,
      actor_type: "user",
      actor_id: actor_id(actor),
      action: String.replace_prefix(event, "config.", ""),
      resource_type: "agent",
      resource_id: agent_id(agent),
      metadata: %{
        agent_id: agent_id(agent),
        path: safe_path(path),
        old_sha256: old_sha,
        new_sha256: new_sha,
        current_sha256: current_sha,
        result: outcome
      }
    }

    case Audit.record(attrs) do
      {:ok, _} -> :ok
      {:error, _} -> Logger.warning("[Agents.ConfigFiles] audit row not recorded for #{event}")
    end
  end

  defp actor_id(%{id: id}) when is_binary(id) do
    case Platform.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp actor_id(_), do: nil

  defp agent_id(%Agent{id: id}), do: id
  defp agent_id(_), do: nil

  defp safe_path(path) when is_binary(path), do: String.slice(path, 0, 255)
  defp safe_path(_), do: nil

  defp reason_name(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_name({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_name(_), do: "error"
end
