# Dev-only server probe for the tab-switch harness (task 01a17b00 stage 1).
#
# NOT part of the application and never in any config. The harness loads it
# into a running DEV node over Erlang distribution (`elixir --rpc-eval`,
# `Code.eval_file/1` on the node) and reads it back the same way, so a prod
# build has no trace of it.
#
# What it records, per LiveView process that mounts after `reset/0`:
#   * view module and connected? flag;
#   * mount and handle_params durations ([:phoenix, :live_view, :mount|
#     :handle_params, :stop]);
#   * Repo query count and summed query time per phase (mount, handle_params,
#     between, until the first handle_event of the view or one of its
#     components), from [:platform, :repo, :query]
#     emitted in that process;
#   * [:platform_web, :tasks, :refresh_board, :stop] count;
#   * calls to Platform.Tasks.count_by_scope/1 and the project/epic opts of
#     each Platform.Tasks.list_all_tasks/1 call (erlang call tracing).
#
# Only module names, durations and counts are kept. No query text, no
# params, no assigns, no user data.

defmodule TabSwitchProbe do
  @moduledoc false

  @table :tab_switch_probe
  @holder :tab_switch_probe_holder
  @handler "tab-switch-probe"

  @events [
    [:phoenix, :live_view, :mount, :start],
    [:phoenix, :live_view, :mount, :stop],
    [:phoenix, :live_view, :handle_params, :start],
    [:phoenix, :live_view, :handle_params, :stop],
    [:phoenix, :live_view, :handle_event, :start],
    [:phoenix, :live_component, :handle_event, :start],
    [:platform, :repo, :query],
    [:platform_web, :tasks, :refresh_board, :stop]
  ]

  def install do
    unless Process.whereis(@holder) do
      parent = self()

      pid =
        spawn(fn ->
          :ets.new(@table, [:named_table, :public, :duplicate_bag])
          Process.register(self(), @holder)
          send(parent, :ready)
          trace_loop()
        end)

      receive do
        :ready -> :ok
      after
        5_000 -> raise "probe holder did not start"
      end

      _ = :telemetry.detach(@handler)
      :ok = :telemetry.attach_many(@handler, @events, &__MODULE__.handle/4, nil)

      :erlang.trace(:all, true, [:call, {:tracer, pid}])
      :erlang.trace_pattern({Platform.Tasks, :count_by_scope, :_}, true, [:local])
      :erlang.trace_pattern({Platform.Tasks, :list_all_tasks, :_}, true, [:local])
    end

    :ok
  end

  def uninstall do
    _ = :telemetry.detach(@handler)
    :erlang.trace_pattern({Platform.Tasks, :_, :_}, false, [:local])

    case Process.whereis(@holder) do
      nil ->
        :ok

      pid ->
        :erlang.trace(:all, false, [:call])
        Process.exit(pid, :kill)
        :ok
    end
  end

  def reset do
    install()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp trace_loop do
    receive do
      {:trace, pid, :call, {Platform.Tasks, :count_by_scope, _args}} ->
        :ets.insert(@table, {pid, :count_by_scope, now()})

      {:trace, pid, :call, {Platform.Tasks, :list_all_tasks, args}} ->
        opts = List.first(args) || []

        shape =
          if is_list(opts),
            do: %{
              project: if(Keyword.get(opts, :project_id), do: "one", else: "all"),
              epic: if(Keyword.get(opts, :epic_id), do: "one", else: "all")
            },
            else: %{project: "?", epic: "?"}

        :ets.insert(@table, {pid, :list_all_tasks, now(), shape})

      _ ->
        :ok
    end

    trace_loop()
  end

  defp now, do: System.monotonic_time(:microsecond)

  # Runs in the emitting process. Must never raise (a raising handler is
  # detached VM-wide).
  def handle(event, measurements, metadata, _config) do
    try do
      do_handle(event, measurements, metadata)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp do_handle([:phoenix, :live_view, :mount, :start], _m, meta) do
    Process.put(:tab_switch_probe_phase, :mount)

    :ets.insert(
      @table,
      {self(), :mount_start, now(), inspect(view(meta)), connected?(meta)}
    )
  end

  defp do_handle([:phoenix, :live_view, :mount, :stop], m, _meta) do
    Process.put(:tab_switch_probe_phase, :between)
    :ets.insert(@table, {self(), :mount_stop, now(), ms(m.duration)})
  end

  defp do_handle([:phoenix, :live_view, :handle_params, :start], _m, _meta) do
    if Process.get(:tab_switch_probe_phase) != :event,
      do: Process.put(:tab_switch_probe_phase, :handle_params)
  end

  defp do_handle([:phoenix, :live_view, :handle_params, :stop], m, _meta) do
    if Process.get(:tab_switch_probe_phase) != :event,
      do: Process.put(:tab_switch_probe_phase, :between)

    :ets.insert(@table, {self(), :handle_params_stop, now(), ms(m.duration)})
  end

  defp do_handle([:phoenix, kind, :handle_event, :start], _m, _meta)
       when kind in [:live_view, :live_component] do
    Process.put(:tab_switch_probe_phase, :event)
  end

  defp do_handle([:platform, :repo, :query], m, _meta) do
    case Process.get(:tab_switch_probe_phase) do
      nil ->
        :ok

      phase ->
        total = Map.get(m, :total_time, 0)

        :ets.insert(
          @table,
          {self(), :query, phase, System.convert_time_unit(total, :native, :microsecond)}
        )
    end
  end

  defp do_handle([:platform_web, :tasks, :refresh_board, :stop], m, _meta) do
    :ets.insert(@table, {self(), :refresh_board, now(), ms(m.duration)})
  end

  defp do_handle(_event, _m, _meta), do: :ok

  defp view(%{socket: %{view: view}}), do: view
  defp view(_), do: nil

  defp connected?(%{socket: socket}) do
    Phoenix.LiveView.connected?(socket)
  rescue
    _ -> nil
  end

  defp connected?(_), do: nil

  defp ms(native), do: System.convert_time_unit(native, :native, :microsecond) / 1000

  @doc "Every mount since reset, oldest first, as a JSON string."
  def dump do
    rows = :ets.tab2list(@table)
    by_pid = Enum.group_by(rows, &elem(&1, 0))

    mounts =
      for {pid, rs} <- by_pid,
          {_, :mount_start, t0, view, connected} <- rs do
        mount_ms = for({_, :mount_stop, _, d} <- rs, do: d) |> List.first()
        params_ms = for {_, :handle_params_stop, _, d} <- rs, do: d
        queries = for {_, :query, phase, us} <- rs, do: {phase, us}

        q_by_phase =
          queries
          |> Enum.group_by(&elem(&1, 0))
          |> Map.new(fn {phase, qs} ->
            {phase, %{count: length(qs), ms: Enum.sum(Enum.map(qs, &elem(&1, 1))) / 1000}}
          end)

        arrival = Enum.reject(queries, fn {phase, _} -> phase == :event end)

        %{
          pid: inspect(pid),
          t0_us: t0,
          view: String.replace_prefix(view, "Elixir.", ""),
          connected: connected,
          mount_ms: mount_ms,
          handle_params_ms: params_ms,
          arrival_queries: length(arrival),
          arrival_query_ms: Enum.sum(Enum.map(arrival, &elem(&1, 1))) / 1000,
          queries_by_phase: q_by_phase,
          refresh_board: Enum.count(rs, &match?({_, :refresh_board, _, _}, &1)),
          refresh_board_ms: for({_, :refresh_board, _, d} <- rs, do: d),
          count_by_scope: Enum.count(rs, &match?({_, :count_by_scope, _}, &1)),
          list_all_tasks:
            rs
            |> Enum.filter(&match?({_, :list_all_tasks, _, _}, &1))
            |> Enum.sort_by(&elem(&1, 2))
            |> Enum.map(&elem(&1, 3))
        }
      end

    mounts |> Enum.sort_by(& &1.t0_us) |> Jason.encode!()
  end
end
