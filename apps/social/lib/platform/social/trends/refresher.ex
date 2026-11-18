defmodule Platform.Social.Trends.Refresher do
  @moduledoc "Refreshes one published Wikipedia pageview day when explicitly enabled."
  use GenServer
  import Ecto.Query
  alias Platform.Repo
  alias Platform.Social.{Profile, Trends}
  alias Platform.Social.Trends.Wikimedia
  alias Platform.Social.Trends.SourceState

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    config = Application.get_env(:social, :trends, [])

    if Keyword.get(config, :enabled, false) == true and
         Keyword.get(config, :refresh_interval_ms) != :infinity do
      send(self(), :refresh)
    end

    {:ok, nil}
  end

  @impl true
  def handle_info(:refresh, state) do
    refresh()

    case Keyword.get(Application.get_env(:social, :trends, []), :refresh_interval_ms, 3_600_000) do
      :infinity ->
        :ok

      interval when is_integer(interval) ->
        Process.send_after(self(), :refresh, interval |> max(900_000) |> min(604_800_000))

      _ ->
        Process.send_after(self(), :refresh, 3_600_000)
    end

    {:noreply, state}
  end

  def refresh(now \\ DateTime.utc_now()) do
    config = Application.get_env(:social, :trends, [])
    wiki = Application.get_env(:social, :trends_wikimedia, [])
    contact = Keyword.get(wiki, :contact)

    cond do
      Keyword.get(config, :enabled, false) != true ->
        {:error, :disabled}

      Keyword.get(config, :source) != "wikimedia_pageviews" ->
        {:error, :invalid_source}

      not is_integer(Keyword.get(config, :max_items, 50)) or
          not (is_integer(Keyword.get(config, :fetch_timeout_ms, 10_000)) and
                   Keyword.get(config, :fetch_timeout_ms, 10_000) in 1..30_000) ->
        {:error, :invalid_configuration}

      not is_binary(contact) or String.trim(contact) == "" ->
        {:error, :missing_contact}

      true ->
        refresh_locked(now, config, contact)
    end
  end

  defp refresh_locked(now, config, contact) do
    result =
      Repo.transaction(
        fn ->
          %{rows: [[locked]]} =
            Repo.query!("SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))", [
              "social:trends:fetch:wikimedia"
            ])

          unless locked, do: Repo.rollback(:refresh_in_progress)
          state = Repo.get(SourceState, "wikimedia_pageviews")

          if state && state.retry_at && DateTime.compare(now, state.retry_at) == :lt,
            do: Repo.rollback(:backoff)

          profile =
            Repo.one(
              from(p in Profile, where: p.studio_enabled == true, limit: 1, lock: "FOR SHARE")
            )

          unless profile, do: Repo.rollback(:no_enabled_profile)

          yesterday = now |> DateTime.to_date() |> Date.add(-1)
          latest = Trends.latest("wikimedia_pageviews").current

          date =
            (state && state.next_date) ||
              if(latest, do: Date.add(latest.reporting_date, 1), else: yesterday)

          if Date.compare(date, yesterday) == :gt do
            :up_to_date
          else
            limit = config |> Keyword.get(:max_items, 50) |> max(1) |> min(100)

            opts = [
              contact: contact,
              timeout_ms: Keyword.get(config, :fetch_timeout_ms, 10_000),
              req_options: Application.get_env(:social, :trends_req_options, [])
            ]

            case Wikimedia.fetch(date, now, limit, opts) do
              {:ok, snapshot} ->
                case Trends.record_snapshot(snapshot) do
                  {:ok, :unchanged} ->
                    save_state(now, "ok", nil, Date.add(date, 1), 0)
                    :up_to_date

                  {:ok, _} ->
                    save_state(now, "ok", nil, Date.add(date, 1), 0)
                    :updated

                  {:error, reason} ->
                    Repo.rollback(reason)
                end

              {:error, {:throttled, headers}} ->
                deadline = retry_deadline(now, headers)
                retry_at = %{deadline | microsecond: {elem(deadline.microsecond, 0), 6}}

                save_state(
                  now,
                  "throttled",
                  retry_at,
                  state && state.next_date,
                  (state && state.not_found_count) || 0
                )

                {:failure, :throttled}

              {:error, reason} ->
                count =
                  if reason == :not_yet_available,
                    do: ((state && state.not_found_count) || 0) + 1,
                    else: (state && state.not_found_count) || 0

                advance? =
                  reason == :not_yet_available and count >= 2 and
                    Date.compare(date, yesterday) == :lt

                save_state(
                  now,
                  if(reason == :not_yet_available, do: "not_yet_available", else: "unavailable"),
                  nil,
                  if(advance?, do: Date.add(date, 1), else: date),
                  if(advance?, do: 0, else: min(count, 2))
                )

                {:failure, reason}
            end
          end
        end,
        timeout: 60_000
      )

    case result do
      {:ok, {:failure, reason}} -> {:error, reason}
      other -> other
    end
  end

  defp save_state(now, status, retry_at, next_date, not_found_count) do
    now = %{now | microsecond: {elem(now.microsecond, 0), 6}}

    Repo.insert!(
      %SourceState{
        source: "wikimedia_pageviews",
        retry_at: retry_at,
        status: status,
        last_attempt_at: now,
        next_date: next_date,
        not_found_count: not_found_count
      },
      on_conflict: [
        set: [
          retry_at: retry_at,
          status: status,
          last_attempt_at: now,
          next_date: next_date,
          not_found_count: not_found_count
        ]
      ],
      conflict_target: :source
    )
  end

  defp retry_deadline(now, [value | _]) when is_binary(value) and byte_size(value) <= 512 do
    if String.valid?(value) do
      parse_retry_deadline(now, value)
    else
      DateTime.add(now, 86_400, :second)
    end
  end

  defp retry_deadline(now, _), do: DateTime.add(now, 86_400, :second)

  # Retry-After seconds and HTTP dates up to 365 days are honored. Malformed,
  # negative, or longer values use a finite 24-hour fallback; past dates wait
  # one second. The same bound applies to both header forms.
  defp parse_retry_deadline(now, value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 and seconds <= 31_536_000 ->
        DateTime.add(now, max(seconds, 1), :second) |> DateTime.truncate(:microsecond)

      {seconds, ""} when seconds < 0 ->
        DateTime.add(now, 86_400, :second)

      {_, ""} ->
        DateTime.add(now, 86_400, :second)

      _ ->
        case :httpd_util.convert_request_date(String.to_charlist(value)) do
          {{y, m, d}, {h, min, s}} ->
            case NaiveDateTime.new(y, m, d, h, min, s, {0, 6}) do
              {:ok, date} ->
                case DateTime.from_naive(date, "Etc/UTC") do
                  {:ok, deadline} ->
                    cond do
                      DateTime.diff(deadline, now, :second) > 31_536_000 ->
                        DateTime.add(now, 86_400, :second)

                      DateTime.compare(deadline, now) == :gt ->
                        deadline

                      true ->
                        DateTime.add(now, 1, :second)
                    end

                  _ ->
                    DateTime.add(now, 86_400, :second)
                end

              _ ->
                DateTime.add(now, 86_400, :second)
            end

          _ ->
            DateTime.add(now, 86_400, :second)
        end
    end
  end
end
