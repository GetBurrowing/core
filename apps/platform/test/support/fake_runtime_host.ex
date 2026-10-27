defmodule Platform.FakeRuntimeHost do
  @moduledoc """
  A stand-in for burrow-cli's host connection, for tests: joins
  `runtime_host:<runtime_id>` through `PlatformWeb.RuntimeSocket`'s channel and
  serves `file.list`, `file.read`, `file.write` and `secret.set` over a tmp
  directory, speaking the channel's real protocol (ref in, `reply` out).

  Options: `:test_process` (the test pid, which owns the channel supervisor), `:runtime_id`, `:root` (the agent folder), `:harness` (hello,
  default `"claude_code"`), `:opt_in` (hello `config_opt_in`, default
  `"owner_only"`), `:raw` (when true the host does NOT redact, to prove core
  redacts again).

  `session.restart` (stage 4): `:session` is `{before_tools, after_tools}`,
  the snapshots the host reports (`"<server>/<tool>"` names); nil (default)
  answers `no_recorded_session`, as a folder with nothing in its roster does;
  `:silent` makes the host never answer a restart (core's timeout path).
  """
  use GenServer
  import Phoenix.ChannelTest

  alias Platform.Agents.ConfigFiles.Redaction

  @endpoint PlatformWeb.Endpoint

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The events the host has served, oldest first."
  def served(pid), do: GenServer.call(pid, :served)

  @doc "Block until the host has joined its topic."
  def ready(pid), do: GenServer.call(pid, :ready)

  @impl true
  def init(opts), do: {:ok, opts, {:continue, :join}}

  # The join runs after init: it starts the channel under the test's own
  # supervisor, which is busy starting this process while init runs.
  @impl true
  def handle_continue(:join, opts) do
    runtime_id = Keyword.fetch!(opts, :runtime_id)
    harness = Keyword.get(opts, :harness, "claude_code")

    adapter =
      case Platform.Agents.Harness.adapter_for(harness) do
        {:ok, a} -> a
        :unsupported -> nil
      end

    socket =
      socket(PlatformWeb.RuntimeSocket, nil, %{runtime_id: runtime_id},
        test_process: Keyword.fetch!(opts, :test_process)
      )

    hello = %{
      "harness" => harness,
      "cli_version" => "0.0.0-test",
      "capabilities" => ["file", "session"],
      "resumes" => true,
      "config_opt_in" => Keyword.get(opts, :opt_in, "owner_only")
    }

    {:ok, _reply, socket} = subscribe_and_join(socket, "runtime_host:#{runtime_id}", hello)

    {:noreply,
     %{
       socket: socket,
       root: Keyword.fetch!(opts, :root),
       adapter: adapter,
       raw: Keyword.get(opts, :raw, false),
       session: Keyword.get(opts, :session),
       silent: Keyword.get(opts, :silent, false),
       served: []
     }}
  end

  @impl true
  def handle_call(:served, _from, state), do: {:reply, Enum.reverse(state.served), state}
  def handle_call(:ready, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info(
        %Phoenix.Socket.Message{event: event, payload: %{"ref" => ref} = payload},
        state
      ) do
    state = %{state | served: [{event, payload["actor_role"]} | state.served]}

    unless event == "session.restart" and state.silent do
      reply = serve(event, payload, state)
      push(state.socket, "reply", Map.put(reply, "ref", ref))
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── ops ────────────────────────────────────────────────────────────

  defp serve("file.list", _payload, state) do
    entries =
      state.root
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn f ->
        rel = Path.relative_to(f, state.root)
        %{"path" => rel, "sha256" => sha(File.read!(f)), "secret" => Redaction.secret_path?(rel)}
      end)

    %{"ok" => %{"entries" => entries}}
  end

  defp serve("file.read", %{"path" => path}, state) do
    with {:ok, full} <- full(state, path), {:ok, bytes} <- File.read(full) do
      shown = if state.raw, do: bytes, else: elem(Redaction.apply(state.adapter, path, bytes), 0)
      %{"ok" => %{"content" => shown, "sha256" => sha(bytes)}}
    else
      _ -> %{"error" => "not_found"}
    end
  end

  defp serve(
         "file.write",
         %{"path" => path, "content" => content, "expected_sha256" => expected},
         state
       ) do
    with {:ok, full} <- full(state, path) do
      current = File.read(full)

      case {expected, current} do
        {nil, {:ok, bytes}} ->
          %{"ok" => %{"status" => "conflict", "current_sha256" => sha(bytes)}}

        {exp, {:ok, bytes}} when is_binary(exp) ->
          if sha(bytes) == exp,
            do: write(full, content),
            else: %{"ok" => %{"status" => "conflict", "current_sha256" => sha(bytes)}}

        {exp, {:error, _}} when is_binary(exp) ->
          %{"ok" => %{"status" => "conflict", "current_sha256" => nil}}

        {nil, {:error, _}} ->
          write(full, content)
      end
    else
      _ -> %{"error" => "invalid_path"}
    end
  end

  defp serve("secret.set", %{"path" => path, "pointer" => pointer, "value" => value}, state) do
    with {:ok, full} <- full(state, path),
         current =
           (case File.read(full) do
              {:ok, b} -> b
              _ -> nil
            end),
         {:ok, merged} <- Redaction.put_secret(path, current, pointer, value) do
      write(full, merged)
    else
      _ -> %{"error" => "invalid"}
    end
  end

  defp serve("session.restart", _payload, %{session: nil}),
    do: %{"error" => "no_recorded_session"}

  defp serve("session.restart", _payload, %{session: {before, after_tools}}) do
    snap = fn tools -> %{"taken_at" => "t", "servers" => [], "tools" => tools} end

    %{
      "ok" => %{
        "outcome" => "ready",
        "resumed" => true,
        "relaunched" => true,
        "before_basis" => "loaded",
        "before" => snap.(before),
        "after" => snap.(after_tools)
      }
    }
  end

  defp serve(_event, _payload, _state), do: %{"error" => "unsupported"}

  defp write(full, content) do
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
    %{"ok" => %{"status" => "ok", "sha256" => sha(content)}}
  end

  defp full(state, path) do
    if String.contains?(path, "..") or String.starts_with?(path, ["/", "~"]),
      do: :error,
      else: {:ok, Path.join(state.root, path)}
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
