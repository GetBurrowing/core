defmodule Platform.Admin.LogTail do
  @moduledoc """
  A bounded in-memory tail of core's own log, for `admin_logs` (task 01a17b10
  stage 3). An OTP `:logger` handler writes formatted lines into a public ETS
  table; `lines/1` reads the newest. Credentials are scrubbed on READ by
  `Platform.AgentHost.Redact`, so a line is never trusted to be clean.

  Installed once by `install/0` at application start. Keeps at most
  #{500} lines; a no-op if the table or handler is already there.
  """

  @table :platform_admin_log_tail
  @max 500
  @handler_id :platform_admin_log_tail

  @doc "Create the table and attach the handler. Idempotent."
  @spec install() :: :ok
  def install do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:ordered_set, :public, :named_table, read_concurrency: true])
    end

    _ = :logger.add_handler(@handler_id, __MODULE__, %{level: :info})
    :ok
  end

  @doc "The newest `n` lines, oldest first, each scrubbed."
  @spec lines(pos_integer()) :: [String.t()]
  def lines(n) when is_integer(n) and n > 0 do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _ ->
        @table
        |> :ets.select_reverse([{{:"$1", :"$2"}, [], [:"$2"]}], n)
        |> case do
          {rows, _cont} -> Enum.reverse(rows)
          :"$end_of_table" -> []
        end
        |> Platform.AgentHost.Redact.lines()
    end
  end

  @doc false
  # :logger handler callback.
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    if :ets.whereis(@table) != :undefined do
      text =
        try do
          case msg do
            {:string, s} -> IO.iodata_to_binary(s)
            {:report, r} -> inspect(r, limit: 20, printable_limit: 500)
            {fmt, args} -> fmt |> :io_lib.format(args) |> IO.iodata_to_binary()
          end
        rescue
          _ -> "[unformattable log message]"
        end

      time = meta |> Map.get(:time, System.os_time(:microsecond)) |> div(1_000_000)
      line = "#{time} [#{level}] " <> String.slice(text, 0, 500)
      :ets.insert(@table, {System.unique_integer([:monotonic]), line})
      trim()
    end

    :ok
  end

  defp trim do
    if :ets.info(@table, :size) > @max + 50 do
      drop = :ets.info(@table, :size) - @max

      Enum.reduce(1..drop, :ets.first(@table), fn _, key ->
        next = :ets.next(@table, key)
        :ets.delete(@table, key)
        next
      end)
    end

    :ok
  end
end
