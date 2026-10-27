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
      topic: if(terminal?, do: "terminal:" <> runtime_id, else: "runtime:" <> runtime_id),
      join_ref: "1",
      ref: 1,
      cli: TerminalFakeCli.new()
    })
  end

  @impl true
  def handle_connect(_conn, state) do
    send(self(), :join)
    {:ok, state}
  end

  @impl true
  def handle_info(:join, state) do
    msg = Jason.encode!(["1", "1", state.topic, "phx_join", %{}])
    Process.send_after(self(), :heartbeat, 25_000)
    {:reply, {:text, msg}, %{state | ref: 2}}
  end

  def handle_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, 25_000)
    {:reply, {:text, Jason.encode!([nil, to_string(state.ref), "phoenix", "heartbeat", %{}])}, %{state | ref: state.ref + 1}}
  end

  def handle_info({:queued, frame}, state), do: {:reply, frame, state}
  def handle_info(_other, state), do: {:ok, state}

  @doc "The count of `in` frames seen so far (read by the mix task on exit)."
  def in_count, do: :persistent_term.get({__MODULE__, :in_count}, 0)

  @impl true
  def handle_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, [_jr, _r, _topic, "phx_reply", %{"status" => "ok"}]} ->
        if state.terminal?, do: IO.puts("joined #{state.topic}"), else: IO.puts("joined #{state.topic} (no terminal)")
        {:ok, state}

      {:ok, [_jr, _r, _topic, "phx_reply", %{"status" => "error"} = reply]} ->
        IO.puts("join refused: #{inspect(reply["response"])}")
        {:close, state}

      {:ok, [_jr, _r, _topic, event, payload]} when is_map(payload) and state.terminal? ->
        run_actions(state, TerminalFakeCli.handle_event(state.cli, event, payload))

      _ ->
        {:ok, state}
    end
  end

  def handle_frame({:binary, <<0, jrs, ts, es, _jr::binary-size(jrs), _t::binary-size(ts), event::binary-size(es), data::binary>>}, state) do
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
          {[{:text, Jason.encode!([st.join_ref, to_string(st.ref), st.topic, event, payload])}], %{st | ref: st.ref + 1}}

        {:push_binary, event, bin}, st ->
          ref = to_string(st.ref)
          jr = st.join_ref

          frame =
            <<0, byte_size(jr), byte_size(ref), byte_size(st.topic), byte_size(event), jr::binary, ref::binary,
              st.topic::binary, event::binary, bin::binary>>

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
