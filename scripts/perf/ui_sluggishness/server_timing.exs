# Temporary server-side timing probe for the ui_sluggishness harness
# (task 01a13884 stage 1). Attaches a :telemetry handler INSIDE the running
# dev BEAM (started with `--sname dev`, as dev-on-moon does) and records
# handle_params / render / handle_event durations with wall-clock stamps, so
# profile.py's per-row start/end times can be joined against them.
#
#   podman cp server_timing.exs dev-platform-<wt>:/tmp/server_timing.exs
#   podman exec dev-platform-<wt> elixir --sname probe$$ --cookie "$(podman exec dev-platform-<wt> cat /root/.erlang.cookie)" /tmp/server_timing.exs start
#   ... run profile.py ...
#   podman exec dev-platform-<wt> elixir --sname probe$$ --cookie ... /tmp/server_timing.exs dump > timings.json
#   podman exec dev-platform-<wt> elixir --sname probe$$ --cookie ... /tmp/server_timing.exs stop
#
# Dev rig only. `stop` detaches the handler and drops the table.

{:ok, host} = :inet.gethostname()
target = :"dev@#{host}"
true = Node.connect(target)

probe = ~S'''
defmodule PerfProbe01a13884 do
  @handler "perf-probe-01a13884"
  @events [
    [:phoenix, :live_view, :mount, :stop],
    [:phoenix, :live_view, :handle_params, :stop],
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :live_view, :render, :stop],
    [:phoenix, :live_component, :handle_event, :stop],
    [:phoenix, :live_component, :update, :stop],
    # Repo time covers what the LiveView events above cannot: handle_info
    # (e.g. {:detail_closed} -> refresh_board) has no telemetry span.
    [:platform, :repo, :query]
  ]

  def start do
    if :ets.whereis(:perf_probe_01a13884) == :undefined do
      parent = self()

      pid =
        spawn(fn ->
          :ets.new(:perf_probe_01a13884, [:named_table, :public, :duplicate_bag])
          send(parent, :ready)

          receive do
            :stop -> :ok
          end
        end)

      receive do
        :ready -> :ok
      end

      Process.register(pid, :perf_probe_01a13884_owner)
    end

    :telemetry.detach(@handler)
    :telemetry.attach_many(@handler, @events, &__MODULE__.handle/4, nil)
  end

  def handle(event, %{duration: d}, meta, _) do
    view =
      case meta do
        %{socket: %{view: v}} -> inspect(v)
        _ -> nil
      end

    component =
      case meta do
        %{component: c} -> inspect(c)
        _ -> nil
      end

    :ets.insert(
      :perf_probe_01a13884,
      {System.os_time(:millisecond), Enum.join(event, "."), view, component,
       System.convert_time_unit(d, :native, :microsecond), meta[:event]}
    )
  end

  def handle([:platform, :repo, :query], %{total_time: t}, meta, _) do
    :ets.insert(
      :perf_probe_01a13884,
      {System.os_time(:millisecond), "repo.query", nil, nil,
       System.convert_time_unit(t, :native, :microsecond), meta[:source]}
    )
  end

  def handle(_, _, _, _), do: :ok

  def dump do
    :perf_probe_01a13884
    |> :ets.tab2list()
    |> Enum.sort()
    |> Enum.map(fn {ts, ev, view, comp, us, name} ->
      %{ts_ms: ts, event: ev, view: view, component: comp, us: us, name: name}
    end)
  end

  def stop do
    :telemetry.detach(@handler)

    case Process.whereis(:perf_probe_01a13884_owner) do
      nil -> :ok
      pid -> send(pid, :stop)
    end

    :ok
  end
end
'''

case System.argv() do
  ["start"] ->
    :rpc.call(target, Code, :eval_string, [probe])
    IO.inspect(:rpc.call(target, PerfProbe01a13884, :start, []), label: "start")

  ["dump"] ->
    rows = :rpc.call(target, PerfProbe01a13884, :dump, [])
    IO.puts(:rpc.call(target, Jason, :encode!, [rows]))

  ["stop"] ->
    IO.inspect(:rpc.call(target, PerfProbe01a13884, :stop, []), label: "stop")
end
