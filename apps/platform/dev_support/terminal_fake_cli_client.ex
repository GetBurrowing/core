defmodule PlatformWeb.TerminalFakeCli.Client do
  @moduledoc """
  WebSocket transport for `mix platform.terminal_fake_cli` (dev and test only).
  Speaks Phoenix serializer V2 and drives `PlatformWeb.TerminalFakeCli`.
  """
  use WebSockex

  alias PlatformWeb.TerminalFakeCli

  def start(url, runtime_id, terminal?) do
    WebSockex.start(url, __MODULE__, %{
      runtime_id: runtime_id,
      terminal?: terminal?,
      # The channel plugin holds `runtime:<id>` (presence); the CLI bridge holds
      # `terminal:<id>`. A fake that stood in for the bridge alone would read as
      # offline, so it joins both and `--no-terminal` drops only the second.
      topic: "terminal:" <> runtime_id,
      runtime_topic: "runtime:" <> runtime_id,
      join_ref: "2",
      ref: 3,
      cli: TerminalFakeCli.new(line_mode: true)
    })
  end

  @impl true
  def handle_connect(_conn, state) do
    send(self(), :join)
    {:ok, state}
  end

  @impl true
  def handle_info(:join, state) do
    Process.send_after(self(), :heartbeat, 25_000)

    if state.terminal? do
      send(self(), {:queued, {:text, Jason.encode!(["2", "2", state.topic, "phx_join", %{}])}})
    end

    {:reply, {:text, Jason.encode!(["1", "1", state.runtime_topic, "phx_join", %{}])}, state}
  end

  def handle_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, 25_000)

    {:reply, {:text, Jason.encode!([nil, to_string(state.ref), "phoenix", "heartbeat", %{}])},
     %{state | ref: state.ref + 1}}
  end

  def handle_info({:queued, frame}, state), do: {:reply, frame, state}
  def handle_info(_other, state), do: {:ok, state}

  @doc "The count of `in` frames seen so far (read by the mix task on exit)."
  def in_count, do: :persistent_term.get({__MODULE__, :in_count}, 0)

  @impl true
  def handle_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, [_jr, _r, topic, "phx_reply", %{"status" => "ok"}]} ->
        IO.puts("joined #{topic}")
        {:ok, state}

      {:ok, [_jr, _r, topic, "phx_reply", %{"status" => "error"} = reply]} ->
        IO.puts("join refused on #{topic}: #{inspect(reply["response"])}")
        {:close, state}

      {:ok, [_jr, _r, topic, event, payload]} when is_map(payload) and topic == state.topic ->
        run_actions(state, TerminalFakeCli.handle_event(state.cli, event, payload))

      _ ->
        {:ok, state}
    end
  end

  def handle_frame(
        {:binary,
         <<0, jrs, ts, es, _jr::binary-size(jrs), _t::binary-size(ts), event::binary-size(es),
           data::binary>>},
        state
      ) do
    run_actions(state, TerminalFakeCli.handle_binary(state.cli, event, data))
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  defp run_actions(state, {cli, actions}) do
    state = %{state | cli: cli}
    :persistent_term.put({__MODULE__, :in_count}, TerminalFakeCli.in_count(cli))

    {frames, state} =
      Enum.flat_map_reduce(actions, state, fn
        {:print, line}, st ->
          IO.puts(line)
          {[], st}

        {:push, event, payload}, st ->
          {[{:text, Jason.encode!([st.join_ref, to_string(st.ref), st.topic, event, payload])}],
           %{st | ref: st.ref + 1}}

        {:push_binary, event, bin}, st ->
          ref = to_string(st.ref)
          jr = st.join_ref

          frame =
            <<0, byte_size(jr), byte_size(ref), byte_size(st.topic), byte_size(event), jr::binary,
              ref::binary, st.topic::binary, event::binary, bin::binary>>

          {[{:binary, frame}], %{st | ref: st.ref + 1}}
      end)

    case frames do
      [] -> {:ok, state}
      [first | rest] -> send_all(first, rest, state)
    end
  end

  # WebSockex replies carry one frame; the rest are queued to ourselves.
  defp send_all(first, rest, state) do
    Enum.each(rest, fn f -> send(self(), {:queued, f}) end)
    {:reply, first, state}
  end
end
