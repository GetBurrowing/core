defmodule Platform.Admin.Tools do
  @moduledoc """
  Behaviour of the `admin` bundle (task 01a17b10 stage 3). Definitions are in
  `Platform.Federation.AdminTools`.

  ## One audit wrapper

  Every admin tool goes through `execute/3`, which runs the tool, then writes
  ONE `Platform.Audit.record/1` row, success or failure:

    * `event_type` `"platform.admin.call"`, `action` the tool name,
      `resource_type` `"admin_tool"`, `resource_id` the tool name;
    * `actor_type` `"agent"`, `actor_id` the calling agent's id;
    * `metadata`: `tool`, `owner_id` (`Platform.Accounts.install_owner/0`),
      `args` (redacted, see below), `result` (`"ok"`, `"error"`,
      `"requires_full_root"` or `"forbidden"`), `detail` (a scrubbed reason,
      only on a non-ok result) and `at` (ISO 8601).

  Args are redacted before they are written: a value under any key matching
  `token|secret|key|password` (case-insensitive, at any depth) becomes
  `"[redacted]"`, and every other string passes through
  `Platform.AgentHost.Redact.line/1`. Results are NOT written to the row, only
  their status.

  A destructive tool (restart, deploy, rollback) with full root on also writes
  a `"started"` row first, because restarting core can kill this process
  before the closing row is written.

  There is no confirm or approve argument anywhere in the bundle, and no
  allow-list. The capability boundary is `[agents] full_root`: off, the
  destructive tools return `requires_full_root` naming `agents.full_root`.

  Authorization is `admin.use`, a module-admin permission held only by an admin
  of the ROOT org (`Scope.grant_root_admin/3`) and capped at the runtime's
  owner, so an agent owned by a member or a sub-org admin is refused. The tool
  surface checks it, and this module checks it again.
  """

  require Logger

  alias Platform.Access
  alias Platform.Access.Scope
  alias Platform.AgentHost
  alias Platform.AgentHost.Redact
  alias Platform.Agents.{Agent, NativeAgents}
  alias Platform.Federation
  alias Platform.Repo

  @secret_key ~r/token|secret|key|password/i
  @destructive ~w(admin_restart admin_deploy admin_rollback)
  @manifest_key "agents.full_root"
  @default_service "core-platform"
  @rpc_timeout_ms 15_000
  @rpc_result_cap 8_000
  @max_log_lines 500

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(String.t(), map(), map()) :: result()
  def execute(tool, args, context) when is_binary(tool) and is_map(args) and is_map(context) do
    runtime = Federation.get_runtime_by_runtime_id(context[:runtime_id])
    agent = runtime && Repo.get_by(Agent, runtime_id: runtime.id)

    cond do
      is_nil(runtime) ->
        audit(tool, args, nil, {:error, :forbidden, "no runtime"})
        {:error, error("forbidden", "no runtime for this call")}

      not Access.can?(Scope.for_runtime(runtime), "admin.use") ->
        audit(tool, args, agent, {:error, :forbidden, "admin.use not held"})

        {:error,
         error(
           "forbidden",
           "tool '#{tool}' requires admin.use (root admin), capped at your owner"
         )}

      true ->
        run(tool, args, agent, context)
    end
  end

  defp run(tool, args, agent, context) do
    if tool in @destructive and AgentHost.full_root?(),
      do: audit(tool, args, agent, {:started, nil})

    outcome =
      try do
        dispatch(tool, args, agent, context)
      rescue
        e -> {:error, :failed, Exception.message(e)}
      catch
        kind, reason -> {:error, :failed, "#{kind}: #{inspect(reason)}"}
      end

    audit(tool, args, agent, outcome)

    case outcome do
      {:ok, result} -> {:ok, result}
      {:requires_full_root, result} -> {:ok, result}
      {:error, _kind, detail} -> {:error, error("failed", Redact.line(to_string(detail)))}
    end
  end

  # ── Audit ───────────────────────────────────────────────────────────

  defp audit(tool, args, agent, outcome) do
    {result, detail} =
      case outcome do
        {:ok, _} -> {"ok", nil}
        {:started, _} -> {"started", nil}
        {:requires_full_root, _} -> {"requires_full_root", nil}
        {:error, :forbidden, d} -> {"forbidden", d}
        {:error, _, d} -> {"error", d}
      end

    owner = Platform.Accounts.install_owner()

    metadata =
      %{
        "tool" => tool,
        "owner_id" => owner && owner.id,
        "args" => redact_args(args),
        "result" => result,
        "at" => DateTime.to_iso8601(DateTime.utc_now())
      }
      |> then(fn m ->
        if detail, do: Map.put(m, "detail", Redact.line(to_string(detail))), else: m
      end)

    attrs = %{
      event_type: "platform.admin.call",
      actor_type: "agent",
      actor_id: agent && agent.id,
      resource_type: "admin_tool",
      resource_id: tool,
      action: tool,
      metadata: metadata
    }

    case Platform.Audit.record(attrs) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("[Admin] audit write failed: #{inspect(reason)}")
    end
  end

  @doc "Args as they are written to an audit row. Public so a test can pin the rule."
  @spec redact_args(term()) :: term()
  def redact_args(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} ->
      if Regex.match?(@secret_key, to_string(k)),
        do: {to_string(k), "[redacted]"},
        else: {to_string(k), redact_args(v)}
    end)
  end

  def redact_args(list) when is_list(list), do: Enum.map(list, &redact_args/1)
  def redact_args(s) when is_binary(s), do: Redact.line(s)
  def redact_args(other), do: other

  # ── Tools ───────────────────────────────────────────────────────────

  defp dispatch("admin_health", _args, _agent, _ctx) do
    repo =
      case Repo.query("SELECT 1") do
        {:ok, _} -> "ok"
        {:error, e} -> "error: " <> Redact.line(inspect(e))
      end

    memory =
      case Platform.Memory.health() do
        :ok -> "ok"
        {:error, reason} -> "error: " <> Redact.line(inspect(reason))
        other -> Redact.line(inspect(other))
      end

    host = AgentHost.host()

    {:ok,
     %{
       core: %{status: "ok", node: to_string(node())},
       repo: repo,
       memory: memory,
       agent_host: %{
         configured: AgentHost.configured?(),
         connected: AgentHost.connected?(),
         full_root: AgentHost.full_root?(),
         profile: host && host[:profile],
         description: AgentHost.describe()
       }
     }}
  end

  defp dispatch("admin_logs", args, agent, _ctx) do
    lines = args |> Map.get("lines", 100) |> clamp(1, @max_log_lines)

    case Map.get(args, "source", "core") do
      "core" ->
        {:ok, %{source: "core", lines: Platform.Admin.LogTail.lines(lines)}}

      "agent" ->
        agent_id = Map.get(args, "agent_id") || (agent && agent.id)

        case AgentHost.logs(agent_id, lines: lines) do
          {:ok, out} -> {:ok, %{source: "agent", agent_id: agent_id, lines: Redact.lines(out)}}
          {:error, reason} -> {:error, :failed, "agent logs: #{inspect(reason)}"}
        end

      other ->
        {:error, :failed, "source must be core or agent, got #{inspect(other)}"}
    end
  end

  defp dispatch("admin_env_names", _args, _agent, _ctx) do
    agents =
      for %{agent: a} <- NativeAgents.list() do
        case AgentHost.host_call("host.env_names", %{"agent_id" => a.id}) do
          {:ok, %{"names" => names}} when is_list(names) ->
            %{agent_id: a.id, name: a.name, names: Enum.filter(names, &is_binary/1)}

          {:ok, _} ->
            %{agent_id: a.id, name: a.name, status: "unavailable"}

          {:error, reason} ->
            %{agent_id: a.id, name: a.name, status: to_string(reason)}
        end
      end

    {:ok, %{core: System.get_env() |> Map.keys() |> Enum.sort(), agents: agents}}
  end

  defp dispatch("admin_migrations", args, _agent, _ctx) do
    case Map.get(args, "action", "status") do
      "status" ->
        {:ok, migration_status()}

      "run" ->
        ran = Ecto.Migrator.run(Repo, :up, all: true)
        {:ok, %{ran: ran, status: migration_status()}}

      other ->
        {:error, :failed, "action must be status or run, got #{inspect(other)}"}
    end
  end

  defp dispatch("admin_rpc", args, _agent, _ctx) do
    with expr when is_binary(expr) and expr != "" <- Map.get(args, "expression") do
      bound = Map.get(args, "args", %{})

      task =
        Task.Supervisor.async_nolink(Platform.TaskSupervisor, fn ->
          try do
            {value, _} = Code.eval_string(expr, args: bound)
            {:value, value}
          rescue
            # A test's sandbox owner can be gone by the time this runs.
            e in DBConnection.OwnershipError -> {:raised, Exception.message(e)}
            e -> {:raised, Exception.message(e)}
          end
        end)

      case Task.yield(task, @rpc_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:raised, message}} ->
          {:error, :failed, message}

        {:ok, {:value, value}} ->
          text = value |> inspect(limit: 100, printable_limit: @rpc_result_cap) |> Redact.line()
          {:ok, %{result: String.slice(text, 0, @rpc_result_cap)}}

        {:exit, reason} ->
          {:error, :failed, "rpc exited: #{inspect(reason)}"}

        nil ->
          {:error, :failed, "rpc timed out after #{@rpc_timeout_ms}ms"}
      end
    else
      _ -> {:error, :failed, "expression is required"}
    end
  end

  defp dispatch("admin_restart", args, _agent, _ctx),
    do: host_admin("restart", args)

  defp dispatch("admin_deploy", args, _agent, _ctx) do
    case Map.get(args, "tag") do
      tag when is_binary(tag) and tag != "" -> host_admin("deploy", args)
      _ -> {:error, :failed, "tag is required"}
    end
  end

  defp dispatch("admin_rollback", args, _agent, _ctx), do: host_admin("rollback", args)

  defp dispatch(tool, _args, _agent, _ctx), do: {:error, :failed, "unknown admin tool #{tool}"}

  defp host_admin(op, args) do
    if AgentHost.full_root?() do
      payload =
        %{"op" => op, "service" => Map.get(args, "service") || @default_service}
        |> then(fn p -> if args["tag"], do: Map.put(p, "tag", args["tag"]), else: p end)

      case AgentHost.host_call("host.admin", payload, timeout: 120_000) do
        {:ok, %{"error" => "requires_full_root"} = r} -> {:requires_full_root, requires(r)}
        {:ok, %{"error" => e} = r} -> {:error, :failed, "#{e}: #{r["detail"]}"}
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, :failed, "agent host: #{inspect(reason)}"}
      end
    else
      {:requires_full_root, requires(%{})}
    end
  end

  defp requires(_),
    do: %{
      error: "requires_full_root",
      manifest_key: @manifest_key,
      detail:
        "Set `full_root = true` under [agents] in the install manifest and re-render to enable this tool."
    }

  defp migration_status do
    rows = Ecto.Migrator.migrations(Repo)
    up = for {:up, v, n} <- rows, do: %{version: v, name: n}
    pending = for {:down, v, n} <- rows, do: %{version: v, name: n}
    %{up: length(up), pending: pending, latest: up |> List.last() |> then(&(&1 && &1.version))}
  end

  defp clamp(n, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)
  defp clamp(_, lo, hi), do: clamp(100, lo, hi)

  defp error(code, message),
    do: %{error: message, code: code, recoverable: false, suggestion: message}
end
