defmodule Platform.Sharing.UsageReceiver do
  @moduledoc """
  The broker host's side of anonymous usage counts (task 01a1b678 stage 2),
  behind `POST /api/feedback-broker/v1/usage` and
  `PlatformWeb.Plugs.FeedbackBrokerGate` (404 unless `FEEDBACK_BROKER_SERVER`).

  Accepts exactly the body `Platform.Sharing.UsageEvents.build_body/4`
  builds: `sharing_install_id` (a UUID), `window` (`start` unix seconds and
  `seconds`, both non-negative integers) and `counts`, whose every key must be
  on the SAME pinned list (`UsageEvents.events/0`) with a non-negative integer
  value. Any other key, an unpinned name, or a non-integer refuses the whole
  body with `:invalid_usage`; nothing partial is stored. Unknown top-level
  keys are refused too, so a caller cannot smuggle free text in beside the
  counts.

  One row per (install, window start, event). A resend replaces its own row,
  so a retry never doubles a count.
  """

  alias Platform.Repo
  alias Platform.Sharing.UsageCount
  alias Platform.Sharing.UsageEvents

  @max_count 1_000_000_000
  @max_window_seconds 31 * 24 * 3600
  @keys ~w(sharing_install_id window counts)

  @doc "Validate and store one batch. Returns the number of rows written."
  @spec record(map()) :: {:ok, non_neg_integer()} | {:error, :invalid_usage}
  def record(params) when is_map(params) do
    with {:ok, install_id, start, seconds, counts} <- validate(params) do
      now = DateTime.utc_now()

      rows =
        Enum.map(counts, fn {event, n} ->
          %{
            id: Platform.Types.UUIDv7.generate(),
            sharing_install_id: install_id,
            window_start: start,
            window_seconds: seconds,
            event: event,
            count: n,
            inserted_at: now,
            updated_at: now
          }
        end)

      {written, _} =
        Repo.insert_all(UsageCount, rows,
          on_conflict: {:replace, [:count, :window_seconds, :updated_at]},
          conflict_target: [:sharing_install_id, :window_start, :event]
        )

      {:ok, written}
    end
  end

  def record(_params), do: {:error, :invalid_usage}

  @doc "Validate a batch body without storing it."
  @spec validate(map()) ::
          {:ok, Ecto.UUID.t(), DateTime.t(), non_neg_integer(), %{String.t() => integer()}}
          | {:error, :invalid_usage}
  def validate(%{"window" => %{"start" => start, "seconds" => seconds} = window} = params)
      when is_integer(start) and start >= 0 and is_integer(seconds) and seconds >= 0 and
             seconds <= @max_window_seconds do
    pinned = UsageEvents.events()

    with true <- Enum.sort(Map.keys(params)) == Enum.sort(@keys),
         true <- map_size(window) == 2,
         {:ok, install_id} <- cast_uuid(params["sharing_install_id"]),
         %{} = counts <- params["counts"],
         true <-
           Enum.all?(counts, fn {name, n} ->
             name in pinned and is_integer(n) and n >= 0 and n <= @max_count
           end),
         {:ok, start_at} <- DateTime.from_unix(start) do
      {:ok, install_id, start_at, seconds, counts}
    else
      _ -> {:error, :invalid_usage}
    end
  end

  def validate(_params), do: {:error, :invalid_usage}

  defp cast_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp cast_uuid(_value), do: :error
end
