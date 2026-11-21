defmodule Platform.Social.Analytics.Backoff do
  @moduledoc "Bounded provider Retry-After policy and the install-wide analytics deadline for its shared key."
  alias Platform.Repo
  alias Platform.Social.Analytics.SyncState

  @doc "Valid seconds up to one year; invalid or oversized values defer for one day."
  def delay(seconds) when is_integer(seconds) and seconds in 0..31_536_000, do: max(seconds, 1)
  def delay(_), do: 86_400

  @doc "Worker-only. Call while holding the analytics request advisory lock."
  def deadline(now) do
    case Repo.aggregate(SyncState, :max, :provider_retry_at) do
      nil -> nil
      at -> if DateTime.compare(at, now) == :gt, do: at
    end
  end
end
