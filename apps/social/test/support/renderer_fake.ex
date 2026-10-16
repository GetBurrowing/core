defmodule Platform.Social.Renderer.Fake do
  @moduledoc """
  A test renderer (Social 5/7): writes a tiny placeholder file at `out_path`
  and answers like a real render, with no ffmpeg.

  Programmable, process-independent (the render runs in the queue's task,
  not the test process), via a named Agent started on demand:

    * `fail_next(reason)` - the next render returns `{:error, reason}`;
    * `raise_next()` - the next render raises (a crashed task);
    * `block_next(pid)` - the next render sends `{:fake_render_blocked,
      ref, render_pid}` to `pid` and waits for `{:release, ref}` (or
      `{:release, ref, result}`) before it returns;
    * `preflight_result(r)` - what `preflight/0` returns;
    * `calls()` - every input rendered so far, oldest first; `reset()`.

  The answer's `duration_s` is the clip length plus the end card, so a
  test can check what a real render would measure.

  Tests that program the Fake share one Agent and so run `async: false`.
  """

  @behaviour Platform.Social.Renderer

  @name __MODULE__

  defp ensure do
    case Process.whereis(@name) do
      nil ->
        case Agent.start(fn -> initial() end, name: @name) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  defp initial, do: %{next: [], calls: [], preflight: :ok}

  def reset, do: Agent.update(ensure(), fn _ -> initial() end)
  def fail_next(reason), do: push({:fail, reason})
  def raise_next, do: push(:raise)
  def block_next(pid), do: push({:block, pid})
  def preflight_result(result), do: Agent.update(ensure(), &%{&1 | preflight: result})
  def calls, do: Agent.get(ensure(), &Enum.reverse(&1.calls))

  defp push(action), do: Agent.update(ensure(), &%{&1 | next: &1.next ++ [action]})

  @impl true
  def preflight, do: Agent.get(ensure(), & &1.preflight)

  @impl true
  def render(input) do
    action =
      Agent.get_and_update(ensure(), fn state ->
        {next, rest} =
          case state.next do
            [n | rest] -> {n, rest}
            [] -> {:ok, []}
          end

        {next, %{state | next: rest, calls: [input | state.calls]}}
      end)

    case action do
      :ok ->
        write(input)

      {:fail, reason} ->
        {:error, reason}

      :raise ->
        raise "fake renderer crashed"

      {:block, pid} ->
        ref = make_ref()
        send(pid, {:fake_render_blocked, ref, self()})

        receive do
          {:release, ^ref} -> write(input)
          {:release, ^ref, result} -> result
        end
    end
  end

  defp write(input) do
    input = Map.merge(Platform.Social.Renderer.defaults(), input)
    File.mkdir_p!(Path.dirname(input.out_path))

    File.write!(
      input.out_path,
      "fake mp4 " <> Integer.to_string(System.unique_integer([:positive]))
    )

    {:ok,
     %{
       path: input.out_path,
       duration_s: Float.round((input.end_s - input.start_s + input.end_card_s) * 1.0, 3),
       width: input.width,
       height: input.height,
       byte_size: File.stat!(input.out_path).size
     }}
  end
end
