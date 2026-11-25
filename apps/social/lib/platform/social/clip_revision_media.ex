defmodule Platform.Social.ClipRevisionMedia do
  @moduledoc false
  alias Platform.Social.Renderer.Ffmpeg
  # Covers uncached help, the media deadline, and both termination waits.
  @task_budget 80_000

  def prepare(bytes) do
    dir = Path.expand(Path.join(System.tmp_dir!(), "social-recut-" <> Ecto.UUID.generate()))
    path = Path.join(dir, "input.video")

    with {_, 0} <- System.cmd("mkdir", ["-m", "700", dir], stderr_to_stdout: true),
         :ok <- File.write(path, bytes, [:exclusive]),
         :ok <- File.chmod(path, 0o600) do
      result = supervised_probe(path)
      finish(result, dir, path, byte_size(bytes))
    else
      _ ->
        # No probe has been started on this allocation failure.
        File.rm(path)
        File.rmdir(dir)
        {:error, :media_preparation_failed}
    end
  end

  defp supervised_probe(path) do
    task =
      Task.Supervisor.async_nolink(Platform.TaskSupervisor, fn -> Ffmpeg.probe_owned(path) end)

    case Task.yield(task, @task_budget) do
      {:ok, result} ->
        result

      {:exit, _} ->
        uncertain()

      nil ->
        # A task's exit cannot attest to an OS child's exit.
        Task.shutdown(task, :brutal_kill)
        uncertain()
    end
  catch
    _, _ -> uncertain()
  end

  defp uncertain,
    do:
      {:error,
       {:probe_lifecycle, %{child_exit: :unconfirmed, input_used?: true, output_dir: nil}}}

  defp finish({:error, {:probe_lifecycle, details}}, dir, path, _size) do
    # Even confirmed-exit lifecycle failures retain a private report of any
    # output obligation. Unconfirmed input is never deleted here.
    report = Map.merge(details, %{input_path: path, automatic_retry: false})
    retain_report(dir, report)
    {:error, :probe_lifecycle}
  end

  defp finish(result, dir, path, size) do
    removed = File.rm(path)
    directory_removed = File.rmdir(dir)

    if removed in [:ok, {:error, :enoent}] and directory_removed == :ok do
      case result do
        {:ok, %{duration_s: duration, width: width, height: height}}
        when is_number(duration) and duration > 0 and is_integer(width) and width > 0 and
               is_integer(height) and height > 0 ->
          {:ok,
           %{
             media: %{
               "duration_s" => duration,
               "width" => width,
               "height" => height,
               "byte_size" => size
             },
             source: "server_probe"
           }}

        _ ->
          {:error, :unreadable_video}
      end
    else
      retain_report(dir, %{
        child_exit: :confirmed,
        input_used?: true,
        input_path: path,
        output_dir: nil,
        automatic_retry: false
      })

      {:error, :probe_lifecycle}
    end
  end

  defp retain_report(dir, report) do
    path = Path.join(dir, "cleanup.json")
    # The directory is private; report values and paths never cross the API.
    with :ok <- File.write(path, Jason.encode!(report), [:exclusive]),
         :ok <- File.chmod(path, 0o600),
         do: :ok
  end
end
