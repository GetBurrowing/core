defmodule Platform.Responsibilities.Cron do
  @moduledoc """
  Pure-functional helper that computes the next fire `DateTime` for a
  5-field cron spec (ADR-0041 M6 stage 2).

  The grammar mirrors the lightweight cron grammar already validated by
  `Platform.Responsibilities.Responsibility.changeset/2`: five
  whitespace-separated fields ordered as

      "minute hour day-of-month month day-of-week"

  with each field being `*`, a non-negative integer, a `N-M` range, a
  `*/S` step, an `N-M/S` ranged step, or a comma-separated list of any
  of those. The router parses the string into a `t:spec/0` map (nil =
  wildcard) and hands that map to `next_fire_after/2`.

  The implementation deliberately does NOT depend on `:quantum`. It
  mirrors the search shape of
  `Platform.Agents.SystemEventScheduler.next_fire_time/3` — generate
  every candidate fire time inside a fixed horizon, drop the past, take
  the earliest. Here the horizon walks at minute granularity for up to
  366 days so any combination of `day` + `month` + `dow` fields still
  finds a hit (e.g. `0 0 29 2 *` resolves on the next leap day).

  We revisit `:quantum` if and only if either of these thresholds gets
  crossed: more than 50 cron triggers, or sub-minute granularity.
  Neither is on the roadmap.
  """

  @typedoc """
  Parsed 5-field cron spec. `nil` on any field means wildcard. The
  non-wildcard value is a `MapSet` of integers — one per matching
  value of that field (e.g. `*/15` on the minute field expands to
  `MapSet.new([0, 15, 30, 45])`).
  """
  @type spec :: %{
          minute: MapSet.t(non_neg_integer()) | nil,
          hour: MapSet.t(non_neg_integer()) | nil,
          day: MapSet.t(non_neg_integer()) | nil,
          month: MapSet.t(non_neg_integer()) | nil,
          dow: MapSet.t(non_neg_integer()) | nil
        }

  # 4 years covers every leap-day edge case (Feb 29 only exists once
  # per 4 years; the cron spec has no year field, so the worst-case
  # next-fire walk is ~4 years for `0 0 29 2 *` evaluated on March 1
  # of a non-leap year).
  @max_horizon_minutes 4 * 366 * 24 * 60

  @doc """
  Parse a cron expression string into a `t:spec/0` map.

  Returns `{:ok, spec}` on success, `{:error, reason}` if the
  expression doesn't have 5 fields or any field is unparseable. The
  schema-level changeset rejects malformed expressions at write time;
  this parser is the runtime second line of defence so a corrupted
  row can't crash the Router tick.
  """
  @spec parse(String.t()) :: {:ok, spec()} | {:error, term()}
  def parse(expression) when is_binary(expression) do
    case String.split(String.trim(expression), ~r/\s+/, trim: true) do
      [minute, hour, day, month, dow] ->
        with {:ok, m} <- parse_field(minute, 0, 59),
             {:ok, h} <- parse_field(hour, 0, 23),
             {:ok, d} <- parse_field(day, 1, 31),
             {:ok, mo} <- parse_field(month, 1, 12),
             {:ok, w} <- parse_field(dow, 0, 6) do
          {:ok, %{minute: m, hour: h, day: d, month: mo, dow: w}}
        end

      fields ->
        {:error, {:bad_field_count, length(fields)}}
    end
  end

  @doc """
  Return the next `DateTime` strictly after `now` (UTC, microsecond
  precision) that matches every set field in `spec`.

  `nil` fields are treated as wildcards. The search horizon is
  capped at 366 days; if no candidate is found within that window
  the function returns `{:error, :no_match_within_horizon}` rather
  than looping forever. In practice every well-formed spec resolves
  inside the first 12 months.

  ## Options

    * `:timezone` — IANA time-zone name (e.g. `"America/Chicago"`) to
      interpret the cron spec's minute/hour/day/month/dow in. The
      returned DateTime is still UTC — only the *matching predicate*
      runs against the local-time representation. Absent, `nil`, or
      `"UTC"`/`"Etc/UTC"` are equivalent and preserve the pre-timezone
      behaviour byte-for-byte. Requires a configured
      `Calendar.time_zone_database/0` (Tzdata in this app; see
      `config/config.exs`). DST transitions Just Work: the search
      walks UTC minute-by-minute and evaluates matches in local time,
      so the spring-forward gap is naturally skipped and the fall-back
      overlap is entered once (matching standard cron semantics).
  """
  @spec next_fire_after(DateTime.t(), spec()) ::
          {:ok, DateTime.t()} | {:error, :no_match_within_horizon}
  @spec next_fire_after(DateTime.t(), spec(), keyword()) ::
          {:ok, DateTime.t()} | {:error, :no_match_within_horizon | {:bad_timezone, String.t()}}
  def next_fire_after(now, spec, opts \\ [])

  def next_fire_after(%DateTime{} = now, spec, opts) when is_map(spec) and is_list(opts) do
    timezone = normalize_timezone(Keyword.get(opts, :timezone))

    # Start at the next minute boundary so we never re-fire the
    # current minute we are already past.
    start =
      now
      |> DateTime.add(60, :second)
      |> Map.merge(%{second: 0, microsecond: {0, 6}})

    search(start, spec, 0, timezone)
  end

  # `nil`, empty, and the UTC aliases collapse to `nil` — no shift
  # happens at all and the search stays byte-identical to the
  # pre-timezone code path.
  defp normalize_timezone(nil), do: nil
  defp normalize_timezone(""), do: nil
  defp normalize_timezone("UTC"), do: nil
  defp normalize_timezone("Etc/UTC"), do: nil
  defp normalize_timezone(tz) when is_binary(tz), do: tz

  # ── Internal: minute-by-minute search ─────────────────────────────────────

  defp search(_candidate, _spec, step, _timezone) when step > @max_horizon_minutes do
    {:error, :no_match_within_horizon}
  end

  defp search(%DateTime{} = candidate_utc, spec, step, timezone) do
    eval = evaluate_at(candidate_utc, timezone)

    cond do
      matches?(eval, spec) ->
        {:ok, candidate_utc}

      not date_matches?(eval, spec) ->
        # Skip forward until the next day boundary in the *evaluation*
        # zone. In UTC (no timezone) that's a whole 24h skip; in a
        # named zone we only skip to the next local midnight because
        # a UTC day straddles two local days.
        {next_utc, skipped} = skip_to_next_local_day(candidate_utc, eval, timezone)
        search(next_utc, spec, step + skipped, timezone)

      true ->
        next = DateTime.add(candidate_utc, 60, :second)
        search(next, spec, step + 1, timezone)
    end
  end

  # Return the DateTime we should feed into the spec-match predicates.
  # In UTC mode that's just the candidate; in TZ mode we shift.
  defp evaluate_at(%DateTime{} = dt, nil), do: dt

  defp evaluate_at(%DateTime{} = dt, tz) when is_binary(tz) do
    DateTime.shift_zone!(dt, tz)
  end

  # UTC-mode skip: 24h of minutes plus a Map.merge to 00:00 of the
  # next UTC day (byte-identical to the pre-timezone implementation).
  defp skip_to_next_local_day(%DateTime{} = utc, _eval, nil) do
    next =
      utc
      |> DateTime.add(86_400, :second)
      |> Map.merge(%{hour: 0, minute: 0, second: 0, microsecond: {0, 6}})

    skipped = (24 - utc.hour) * 60 - utc.minute
    {next, skipped}
  end

  # TZ-mode skip: advance UTC by exactly the number of minutes needed
  # to land at 00:00 of the next *local* day. No Map.merge — the
  # resulting UTC DateTime is unlikely to be at 00:00 UTC.
  defp skip_to_next_local_day(%DateTime{} = utc, %DateTime{} = eval, tz) when is_binary(tz) do
    skipped_min = (24 - eval.hour) * 60 - eval.minute
    next = DateTime.add(utc, skipped_min * 60, :second)
    {next, skipped_min}
  end

  defp matches?(%DateTime{} = dt, spec) do
    field_match?(spec.minute, dt.minute) and
      field_match?(spec.hour, dt.hour) and
      date_matches?(dt, spec)
  end

  defp date_matches?(%DateTime{} = dt, spec) do
    field_match?(spec.day, dt.day) and
      field_match?(spec.month, dt.month) and
      field_match?(spec.dow, day_of_week_cron(dt))
  end

  defp field_match?(nil, _value), do: true
  defp field_match?(%MapSet{} = set, value), do: MapSet.member?(set, value)

  # Cron `dow` is 0..6 with Sunday = 0; `Date.day_of_week/1` is 1..7
  # with Monday = 1, Sunday = 7. Translate.
  defp day_of_week_cron(%DateTime{} = dt) do
    case dt |> DateTime.to_date() |> Date.day_of_week() do
      7 -> 0
      n -> n
    end
  end

  # ── Internal: cron field parser ───────────────────────────────────────────

  defp parse_field("*", _lo, _hi), do: {:ok, nil}

  defp parse_field(field, lo, hi) do
    parts = String.split(field, ",", trim: true)

    Enum.reduce_while(parts, {:ok, MapSet.new()}, fn part, {:ok, acc} ->
      case parse_atom(part, lo, hi) do
        {:ok, values} -> {:cont, {:ok, MapSet.union(acc, values)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, set} ->
        if MapSet.size(set) == 0 do
          {:error, {:empty_field, field}}
        else
          {:ok, set}
        end

      err ->
        err
    end
  end

  defp parse_atom(atom, lo, hi) do
    case String.split(atom, "/", parts: 2) do
      [base, step] ->
        with {:ok, base_set} <- parse_base(base, lo, hi),
             {:ok, step_n} <- parse_int(step) do
          if step_n <= 0 do
            {:error, {:bad_step, atom}}
          else
            filtered =
              base_set
              |> Enum.filter(fn n -> rem(n - Enum.min(base_set), step_n) == 0 end)
              |> MapSet.new()

            {:ok, filtered}
          end
        end

      [base] ->
        parse_base(base, lo, hi)
    end
  end

  defp parse_base("*", lo, hi), do: {:ok, MapSet.new(lo..hi)}

  defp parse_base(base, lo, hi) do
    case String.split(base, "-", parts: 2) do
      [lo_str, hi_str] ->
        with {:ok, low} <- parse_int(lo_str),
             {:ok, high} <- parse_int(hi_str) do
          cond do
            low < lo or high > hi ->
              {:error, {:out_of_range, base}}

            low > high ->
              {:error, {:bad_range, base}}

            true ->
              {:ok, MapSet.new(low..high)}
          end
        end

      [single] ->
        with {:ok, n} <- parse_int(single) do
          if n < lo or n > hi do
            {:error, {:out_of_range, single}}
          else
            {:ok, MapSet.new([n])}
          end
        end
    end
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, {:not_an_int, str}}
    end
  end
end
