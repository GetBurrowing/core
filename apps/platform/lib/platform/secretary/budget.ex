defmodule Platform.Secretary.Budget do
  @moduledoc """
  What the secretary may spend (task 01a1b721 stage 3). Deterministic.

  ## Charged at dispatch, never refunded

  A batch's reservation is `ceil(byte_size(prompt) / 4) + max_output_tokens`,
  written on the batch row before the host is asked. When the host answers,
  the batch's `actual_tokens` is the sum of the usage fields it reported
  (real usage). A batch counts against today as `max(reserved, actual)`, so a
  failed or timed-out batch keeps its whole reservation and a batch that
  over-ran its estimate is charged what it really used.

  ## Two ceilings

    * per person: `Settings.daily_token_ceiling` when the person set one, else
      the policy payload's `daily_token_ceiling`; "today" is the person's own
      day in their `time_zone`;
    * install-wide: the install payload's `install_daily_token_ceiling` over
      every person's batches today (UTC day).

  `check/3` refuses a reservation that would take EITHER total over its
  ceiling. The caller then records the batch `budget_exhausted` and uses the
  fallback; no host call is made.
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Secretary.{Batch, Settings}

  @doc "The reservation for a prompt and an output allowance."
  @spec reserve(String.t(), non_neg_integer()) :: pos_integer()
  def reserve(prompt, max_output_tokens) when is_binary(prompt) do
    div(byte_size(prompt) + 3, 4) + max_output_tokens
  end

  @doc "The sum of the usage fields a host reported."
  @spec actual(map() | nil) :: non_neg_integer()
  def actual(%{} = usage) do
    usage
    |> Map.take([
      :input_tokens,
      :output_tokens,
      :cache_read_tokens,
      :cache_creation_tokens,
      "input_tokens",
      "output_tokens",
      "cache_read_tokens",
      "cache_creation_tokens"
    ])
    |> Map.values()
    |> Enum.filter(&(is_integer(&1) and &1 >= 0))
    |> Enum.sum()
  end

  def actual(_usage), do: 0

  @doc "The person's ceiling: their own setting, else the payload's."
  @spec person_ceiling(map(), map()) :: pos_integer()
  def person_ceiling(settings, payload) do
    case settings["daily_token_ceiling"] do
      n when is_integer(n) and n > 0 -> n
      _ -> payload["daily_token_ceiling"]
    end
  end

  @doc """
  Tokens charged to `user_id` today, in the person's own time zone. Options:
  `:now`, `:time_zone` (default the person's setting).
  """
  @spec spent_today(Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def spent_today(user_id, opts \\ []) when is_binary(user_id) do
    if Platform.UUID.valid?(user_id) do
      now = Keyword.get(opts, :now, DateTime.utc_now())
      tz = Keyword.get_lazy(opts, :time_zone, fn -> Settings.get(user_id)["time_zone"] end)
      {from, to} = local_day(now, tz)

      Batch
      |> where([b], b.user_id == ^user_id)
      |> charged_between(from, to)
    else
      0
    end
  end

  @doc "Tokens charged across the install today (UTC). Option: `:now`."
  @spec install_spent_today(keyword()) :: non_neg_integer()
  def install_spent_today(opts \\ []) do
    {from, to} = local_day(Keyword.get(opts, :now, DateTime.utc_now()), "Etc/UTC")
    charged_between(Batch, from, to)
  end

  @doc """
  May `user_id` reserve `reserve` more tokens now? `:ok`, or `{:error,
  :person_ceiling | :install_ceiling}`. `payload` is the person's,
  `install_payload` the install's (default the same map).
  Options: `:now`, `:settings`, `:install_payload`.
  """
  @spec check(Ecto.UUID.t(), pos_integer(), map(), keyword()) ::
          :ok | {:error, :person_ceiling | :install_ceiling}
  def check(user_id, reserve, payload, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    settings = Keyword.get_lazy(opts, :settings, fn -> Settings.get(user_id) end)
    install_payload = Keyword.get(opts, :install_payload, payload)

    cond do
      spent_today(user_id, now: now, time_zone: settings["time_zone"]) + reserve >
          person_ceiling(settings, payload) ->
        {:error, :person_ceiling}

      install_spent_today(now: now) + reserve > install_payload["install_daily_token_ceiling"] ->
        {:error, :install_ceiling}

      true ->
        :ok
    end
  end

  @doc "The `[from, to)` UTC bounds of `now`'s local day in `tz`."
  @spec local_day(DateTime.t(), String.t() | nil) :: {DateTime.t(), DateTime.t()}
  def local_day(now, tz) do
    tz = tz || "Etc/UTC"

    with {:ok, local} <- DateTime.shift_zone(now, tz),
         date = DateTime.to_date(local),
         {:ok, from} <- start_of(date, tz),
         {:ok, to} <- start_of(Date.add(date, 1), tz) do
      {from, to}
    else
      _ -> local_day(now, "Etc/UTC")
    end
  end

  defp start_of(date, tz) do
    case DateTime.new(date, ~T[00:00:00], tz) do
      {:ok, dt} -> {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
      {:ambiguous, first, _} -> {:ok, DateTime.shift_zone!(first, "Etc/UTC")}
      {:gap, _, later} -> {:ok, DateTime.shift_zone!(later, "Etc/UTC")}
      other -> other
    end
  end

  defp charged_between(query, from, to) do
    query
    |> where([b], b.dispatched_at >= ^from and b.dispatched_at < ^to)
    |> select(
      [b],
      coalesce(
        sum(
          fragment(
            "GREATEST(?, COALESCE(?, 0))",
            b.reserved_tokens,
            b.actual_tokens
          )
        ),
        0
      )
    )
    |> Repo.one()
    |> to_int()
  end

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n
  defp to_int(_), do: 0
end
