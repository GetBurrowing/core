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
      restart(actor, agent)                       {:ok, diff} | {:error, reason}   (stage 4)
      pending_changes(agent)                      [path]
      running_task(agent)                         %{id, title} | nil

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
  alias Platform.Federation
  alias Platform.Federation.RuntimeHosts

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

  # ── restart (stage 4) ──────────────────────────────────────────────

  @restart_host_timeout_ms 150_000

  @doc """
  Restart the agent's session so saved config takes effect, and say what it
  changed: `{:ok, diff}` or `{:error, reason}`.

  Same gate as a write (`Access.authorize/2`). Federated: `session.restart`
  over `runtime_host:<id>`, carrying the actor's role so the CLI checks its own
  opt-in. Native: the existing `agent.restart` with a ref
  (`AgentHost.restart_with_tools/2`); claude_code only, since the agent host
  runs no other harness.

  `diff` is `%{before, after, added, removed, outcome, resumed, before_basis,
  restarted_at}`. `before`/`after` are tool names: Burrow's own
  (`burrow/<tool>`, computed here from the runtime's tool surface) plus what
  the host probed from each MCP server the harness loads (`<server>/<tool>`,
  or `unreachable:<server>`). nil when the host did not probe (a
  `needs_login` agent).

  Audit: `config.restart_requested` when asked, `config.restart` with the
  result (outcome, resumed, before/after counts), refusals included. A
  success is broadcast as `{:agent_session_restarted, agent_id, diff}` on
  `restart_topic/1`.
  """
  @spec restart(term(), Agent.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def restart(actor, agent, opts \\ []) do
    record_restart(actor, agent, "config.restart_requested", %{result: "requested"})

    result =
      with {:ok, ctx} <- Access.authorize(actor, agent) do
        run_restart(ctx, opts)
      end

    record_restart(actor, agent, "config.restart", restart_meta(result))

    with {:ok, diff} <- result do
      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        restart_topic(agent.id),
        {:agent_session_restarted, agent.id, diff}
      )
    end

    result
  end

  @doc "PubSub topic for an agent's session restarts (the session strip)."
  def restart_topic(agent_id), do: "agent_config:" <> agent_id

  @doc """
  Saved config changes the running session has not loaded yet: a list of
  paths. Native: `NativeAgents.pending_file_keys/2` (stored versions newer than
  what the host applied at the last start). Federated: paths written through
  this module since the last successful restart (from the audit trail).
  """
  @spec pending_changes(Agent.t()) :: [String.t()]
  def pending_changes(%Agent{} = agent) do
    case Federation.get_runtime_for_agent(agent) do
      %{managed_by: "install"} ->
        NativeAgents.pending_file_keys(
          NativeAgents.list_files(agent),
          Platform.AgentHost.status(agent.id)
        )

      %{} ->
        writes_since_restart(agent.id)

      nil ->
        []
    end
  end

  @doc """
  The task the agent is working on right now, for the restart confirm copy:
  `%{id, title}` of its newest `in_progress` task, or nil.
  """
  @spec running_task(Agent.t()) :: %{id: String.t(), title: String.t()} | nil
  def running_task(%Agent{id: id}) do
    case Platform.Tasks.list_tasks(status: "in_progress", assignee_id: id, assignee_type: "agent") do
      [task | _] -> %{id: task.id, title: task.title}
      [] -> nil
    end
  end

  defp run_restart(%{backend: :host} = ctx, opts) do
    timeout = Keyword.get(opts, :timeout, @restart_host_timeout_ms)
    payload = %{"actor_role" => to_string(Map.get(ctx, :role) || :other)}

    case RuntimeHosts.request(ctx.runtime.runtime_id, "session.restart", payload, timeout) do
      {:ok, %{} = reply} ->
        {:ok,
         diff(ctx, reply["before"], reply["after"], %{
           outcome: str(reply["outcome"]) || "gone",
           resumed: reply["resumed"] == true,
           before_basis: str(reply["before_basis"]) || "now"
         })}

      {:error, _} = error ->
        error
    end
  end

  defp run_restart(%{backend: :workspace_store, runtime: runtime} = ctx, opts) do
    if runtime.harness == "claude_code" do
      case Platform.AgentHost.restart_with_tools(ctx.agent, opts) do
        {:ok, %{outcome: outcome, before: before, after: after_snap}} ->
          {:ok,
           diff(ctx, before, after_snap, %{
             outcome: outcome,
             resumed: ctx.adapter.restart_resumes?(),
             before_basis: "loaded"
           })}

        {:error, :not_connected} ->
          {:error, :host_offline}

        {:error, _} = error ->
          error
      end
    else
      {:error, :unsupported_harness}
    end
  end

  defp diff(ctx, before, after_snap, extra) do
    burrow = burrow_tools(ctx.runtime)
    b = tools_of(before, burrow)
    a = tools_of(after_snap, burrow)

    {added, removed} =
      if is_list(b) and is_list(a), do: {a -- b, b -- a}, else: {[], []}

    Map.merge(extra, %{
      before: b,
      after: a,
      added: Enum.sort(added),
      removed: Enum.sort(removed),
      restarted_at: DateTime.utc_now()
    })
  end

  defp tools_of(%{"tools" => tools}, burrow) when is_list(tools),
    do: Enum.sort(Enum.uniq(burrow ++ Enum.filter(tools, &is_binary/1)))

  defp tools_of(_, _burrow), do: nil

  defp burrow_tools(runtime) do
    runtime
    |> Platform.Federation.ToolAuthorization.tool_names()
    |> Enum.map(&("burrow/" <> to_string(&1)))
  rescue
    _ -> []
  end

  defp str(v) when is_binary(v), do: String.slice(v, 0, 32)
  defp str(_), do: nil

  defp restart_meta({:ok, diff}) do
    %{
      result: "ok",
      outcome: diff.outcome,
      resumed: diff.resumed,
      before_basis: diff.before_basis,
      before_count: diff.before && length(diff.before),
      after_count: diff.after && length(diff.after),
      added_count: length(diff.added),
      removed_count: length(diff.removed)
    }
  end

  defp restart_meta({:error, reason}), do: %{result: "refused:" <> reason_name(reason)}

  defp record_restart(actor, agent, event, meta) do
    attrs = %{
      event_type: event,
      actor_type: "user",
      actor_id: actor_id(actor),
      action: String.replace_prefix(event, "config.", ""),
      resource_type: "agent",
      resource_id: agent_id(agent),
      metadata: Map.put(meta, :agent_id, agent_id(agent))
    }

    case Audit.record(attrs) do
      {:ok, _} -> :ok
      {:error, _} -> Logger.warning("[Agents.ConfigFiles] audit row not recorded for #{event}")
    end
  end

  # One query: ok writes newer than the newest ok `config.restart` row.
  defp writes_since_restart(agent_id) do
    import Ecto.Query

    from(e in Platform.Audit.Event,
      where:
        e.resource_type == "agent" and e.resource_id == ^agent_id and
          e.event_type in ["config.write", "config.secret_set"] and
          fragment("?->>'result' = 'ok'", e.metadata) and
          fragment(
            "? > coalesce((SELECT max(r.inserted_at) FROM audit_events r WHERE r.resource_type = 'agent' AND r.resource_id = ? AND r.event_type = 'config.restart' AND r.metadata->>'result' = 'ok'), '-infinity')",
            e.inserted_at,
            ^agent_id
          ),
      select: fragment("?->>'path'", e.metadata),
      distinct: true
    )
    |> Platform.Repo.all()
    |> Enum.filter(&is_binary/1)
    |> Enum.sort()
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
