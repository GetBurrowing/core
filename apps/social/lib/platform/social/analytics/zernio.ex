defmodule Platform.Social.Analytics.Zernio do
  @moduledoc """
  Read-only Zernio analytics client (Clip Studio 9/9, task 01a16664).

  Contract: https://zernio.com/openapi.json, fetched 2026-10-29.
  `delta/2` preserves feed order and opaque cursors, including empty pages.
  With no cursor the feed returns only its current position: capture it
  before `post/1` baseline reads. The historical endpoint's aggregate
  `analytics` is NEVER used; each `platformAnalytics` entry is separate.

  Delta `postId` is the analytics external post id, which can differ from
  the publisher's Zernio id; baseline responses retain `latePostId` so the
  sync can correlate them without ever matching by platform alone.

  Uses the publisher's base URL/test injection and the install-level Vault
  key, never an org key. No automatic HTTP retries: the worker schedules
  another attempt using Retry-After (seconds, or an HTTP date). Pending
  (202) and unavailable (424) return errors without snapshots, so callers
  must retain their last stored values.
  """

  alias Platform.Social.{Secrets, ZernioHTTP}

  @metric_keys ~w(views likes comments shares saves reach)

  @type snapshot :: %{
          post_id: String.t(),
          account_id: String.t(),
          profile_id: String.t() | nil,
          platform: String.t(),
          platform_post_id: String.t(),
          synced_at: DateTime.t(),
          deleted?: boolean(),
          metrics: map()
        }

  @doc "Read one delta page. Optional profile_id filters the vendor feed, not local authorization."
  @spec delta(String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def delta(cursor \\ nil, opts \\ []) do
    params =
      [cursor: cursor, profileId: opts[:profile_id], limit: opts[:limit]]
      |> Enum.reject(fn {_, value} -> is_nil(value) end)

    with {:ok, body} <- get("/v1/analytics/delta", params) do
      decode_delta(body)
    end
  end

  @doc "Read baseline snapshots for one Zernio post; never use the aggregate total."
  @spec post(String.t()) :: {:ok, map()} | {:error, term()}
  def post(post_id) when is_binary(post_id) and post_id != "" do
    with {:ok, body} <- get("/v1/analytics", postId: post_id) do
      decode_post(body)
    end
  end

  @doc """
  Read at most 90 UTC days of followers for one vendor account. Only daily,
  account-grouped rows are accepted; totals and vendor growth are not used.
  Null stays unavailable. A partial page is an error, never a complete series.
  """
  def account_followers(account_id, opts \\ []) do
    finish = Keyword.get(opts, :to_date, Date.utc_today())

    start =
      Keyword.get_lazy(opts, :from_date, fn ->
        if match?(%Date{}, finish), do: Date.add(finish, -89)
      end)

    if is_binary(account_id) and account_id != "" and match?(%Date{}, start) and
         match?(%Date{}, finish) and Date.diff(finish, start) in 0..89 do
      params = [
        accountId: account_id,
        metrics: "followers",
        groupBy: "account",
        granularity: "day",
        attribution: "publish",
        fromDate: Date.to_iso8601(start),
        toDate: Date.to_iso8601(finish),
        limit: 100
      ]

      case get("/v1/metrics/accounts", params,
             redirect: false,
             connect_options: [timeout: 5_000],
             receive_timeout: 15_000
           ) do
        {:ok, body} ->
          decode_followers(body, account_id, start, finish)

        {:error, {:retry_after, status, seconds}} ->
          # Honor valid deadlines up to one year; malformed/negative/oversized
          # values use one day rather than allowing an indefinite deadline.
          delay = Platform.Social.Analytics.Backoff.delay(seconds)

          {:error, {:retry_after, status, delay}}

        error ->
          error
      end
    else
      {:error, :invalid_request}
    end
  end

  defp decode_followers(
         %{
           "data" => data,
           "pagination" => %{"nextCursor" => nil, "hasMore" => false},
           "meta" => %{
             "entity" => "accounts",
             "granularity" => "day",
             "groupBy" => "account",
             "attribution" => "publish",
             "fromDate" => from,
             "toDate" => to,
             "stale" => stale,
             "staleSince" => stale_since
           }
         },
         account_id,
         start,
         finish
       )
       when is_list(data) and is_boolean(stale) and
              (is_nil(stale_since) or is_binary(stale_since)) do
    with true <- from == Date.to_iso8601(start) and to == Date.to_iso8601(finish),
         {:ok, rows} <- decode_all(data, &follower_row(&1, account_id, start, finish)),
         true <- length(rows) == MapSet.size(MapSet.new(rows, & &1.date)) do
      {:ok, %{data: rows, stale: stale, stale_since: stale_since}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp decode_followers(_, _, _, _), do: {:error, :invalid_response}

  defp follower_row(
         %{
           "date" => date,
           "accountId" => id,
           "profileId" => profile,
           "platform" => platform,
           "metrics" => %{"followers" => count}
         },
         id,
         start,
         finish
       )
       when is_binary(date) and is_binary(profile) and profile != "" and
              platform in ["tiktok", "instagram", "youtube", "twitter"] and
              (is_nil(count) or (is_integer(count) and count >= 0)) do
    with {:ok, day} <- Date.from_iso8601(date),
         true <- Date.compare(day, start) != :lt and Date.compare(day, finish) != :gt do
      {:ok,
       %{date: day, account_id: id, profile_id: profile, platform: platform, followers: count}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp follower_row(_, _, _, _), do: {:error, :invalid_response}

  defp get(path, params, options \\ []) do
    with {:ok, key} <- api_key() do
      key
      |> ZernioHTTP.request()
      |> Req.get(Keyword.merge([url: path, params: params, retry: false], options))
      |> response()
    end
  end

  defp api_key do
    case Secrets.zernio_api_key() do
      {:ok, key} -> {:ok, key}
      _ -> {:error, :credentials_unavailable}
    end
  end

  defp response({:ok, %Req.Response{status: 200, body: body}}), do: {:ok, body}
  defp response({:ok, %Req.Response{status: 202}}), do: {:error, :sync_pending}
  defp response({:ok, %Req.Response{status: 424}}), do: {:error, :analytics_unavailable}

  defp response({:ok, %Req.Response{status: status} = response}) when status in [429, 503],
    do: {:error, {:retry_after, status, retry_after(response)}}

  defp response({:ok, %Req.Response{status: status}}), do: {:error, {:http_status, status}}
  defp response({:error, reason}), do: {:error, {:transport, reason}}

  defp retry_after(response) do
    case Req.Response.get_header(response, "retry-after") do
      [value | _] -> parse_retry_after(value)
      _ -> nil
    end
  end

  defp parse_retry_after(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds
      _ -> retry_date(value)
    end
  end

  defp retry_date(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {{_, _, _}, {_, _, _}} = date ->
        {:ok, naive} = NaiveDateTime.from_erl(date)
        max(DateTime.diff(DateTime.from_naive!(naive, "Etc/UTC"), DateTime.utc_now()), 0)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp decode_delta(%{"data" => data, "nextCursor" => cursor, "hasMore" => more})
       when is_list(data) and is_binary(cursor) and cursor != "" and is_boolean(more) do
    with {:ok, snapshots} <- decode_all(data, &delta_snapshot/1) do
      {:ok, %{data: snapshots, next_cursor: cursor, has_more: more}}
    end
  end

  defp decode_delta(_), do: {:error, :invalid_response}

  defp delta_snapshot(%{"profileId" => profile_id} = entry)
       when is_binary(profile_id) and profile_id != "",
       do: snapshot(entry)

  defp delta_snapshot(_), do: {:error, :invalid_response}

  defp snapshot(%{
         "postId" => post_id,
         "accountId" => account_id,
         "profileId" => profile_id,
         "platform" => platform,
         "platformPostId" => platform_post_id,
         "syncedAt" => synced_at,
         "isDeleted" => deleted,
         "metrics" => metrics
       })
       when is_binary(post_id) and post_id != "" and is_binary(account_id) and account_id != "" and
              is_binary(platform) and
              platform != "" and
              is_binary(platform_post_id) and platform_post_id != "" and is_boolean(deleted) and
              is_map(metrics) do
    with {:ok, timestamp} <- timestamp(synced_at) do
      {:ok,
       %{
         post_id: post_id,
         account_id: account_id,
         profile_id: profile_id,
         platform: platform,
         platform_post_id: platform_post_id,
         synced_at: timestamp,
         deleted?: deleted,
         metrics: clean_metrics(metrics)
       }}
    end
  end

  defp snapshot(_), do: {:error, :invalid_response}

  defp decode_post(%{"postId" => post_id, "platformAnalytics" => entries} = body)
       when is_binary(post_id) and post_id != "" and is_list(entries) do
    # A pending/unavailable platform must not erase its old metrics even
    # when the overall response is 200 (for example a partial sync).
    synced = Enum.filter(entries, &(is_map(&1) and &1["syncStatus"] == "synced"))

    with {:ok, snapshots} <- decode_all(synced, &baseline_snapshot(&1, post_id)) do
      {:ok, %{post_id: post_id, late_post_id: body["latePostId"], data: snapshots}}
    end
  end

  defp decode_post(_), do: {:error, :invalid_response}

  defp baseline_snapshot(entry, post_id) do
    metrics = entry["analytics"]

    snapshot(%{
      "postId" => post_id,
      "accountId" => entry["accountId"],
      # The single-post schema has no profileId. The caller must scope the
      # requested post through its local org/profile/account instead.
      "profileId" => nil,
      "platform" => entry["platform"],
      "platformPostId" => entry["platformPostId"],
      "syncedAt" => if(is_map(metrics), do: metrics["lastUpdated"]),
      "isDeleted" => false,
      "metrics" => metrics
    })
  end

  defp decode_all(entries, decoder) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case decoder.(entry) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _} ->
        # Ecto's utc_datetime_usec writer requires precision six even when
        # Zernio sends a whole-second timestamp.
        {:ok, %{timestamp | microsecond: {elem(timestamp.microsecond, 0), 6}}}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp timestamp(_), do: {:error, :invalid_response}

  defp clean_metrics(metrics) do
    for {key, value} <- Map.take(metrics, @metric_keys),
        is_integer(value) and value >= 0,
        into: %{},
        do: {key, value}
  end
end
