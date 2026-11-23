defmodule Platform.CodeMode.PermitDiagnostics do
  @moduledoc false
  alias Platform.CodeMode.Permits

  # native_workers is the application's estimate, not a read of Tokio's pool.
  def snapshot do
    %{
      at_ms: safe(fn -> System.monotonic_time(:millisecond) end),
      workers: safe(fn -> Permits.native_workers() end),
      gate: safe(fn -> Map.take(Permits.status(), [:size, :held, :waiting]) end)
    }
  end

  def report(label, before, after_snapshot) do
    safe(fn ->
      IO.puts(
        :stderr,
        "#{label}: before=#{inspect(before)} after=#{inspect(after_snapshot)} timeout_phase=unknown"
      )
    end)

    :ok
  end

  defp safe(fun) do
    try do
      fun.()
    rescue
      _ -> :unknown
    catch
      _, _ -> :unknown
    end
  end
end
