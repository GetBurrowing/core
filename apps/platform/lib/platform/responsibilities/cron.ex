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
  """
  @spec next_fire_after(DateTime.t(), spec()) ::
          {:ok, DateTime.t()} | {:error, :no_match_within_horizon}
  def next_fire_after(%DateTime{} = now, spec) when is_map(spec) do
    # Start at the next minute boundary so we never re-fire the
    # current minute we are already past.
    start =
      now
      |> DateTime.add(60, :second)
      |> Map.merge(%{second: 0, microsecond: {0, 6}})

    search(start, spec, 0)
  end

  # ── Internal: minute-by-minute search ─────────────────────────────────────

  defp search(_candidate, _spec, step) when step > @max_horizon_minutes do
    {:error, :no_match_within_horizon}
  end

  defp search(%DateTime{} = candidate, spec, step) do
    cond do
      matches?(candidate, spec) ->
        {:ok, candidate}

      not date_matches?(candidate, spec) ->
        # Skip the entire day — none of the date predicates can be
        # satisfied by any minute within it. Reset to 00:00 of the next
        # UTC day so we don't oscillate within the skipped one.
        next =
          candidate
          |> DateTime.add(86_400, :second)
          |> Map.merge(%{hour: 0, minute: 0, second: 0, microsecond: {0, 6}})

        # Step counter advances by the number of minutes we skipped so
        # the horizon cap still bounds the recursion.
        skipped =
          (24 - candidate.hour) * 60 - candidate.minute

        search(next, spec, step + skipped)

      true ->
        next = DateTime.add(candidate, 60, :second)
        search(next, spec, step + 1)
    end
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
