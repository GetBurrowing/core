defmodule PlatformWeb.TimeEntry do
  @moduledoc """
  Parses and formats the time-of-day a person types into a form field
  (task 01a192d6). One parser, shared by the meeting sheet's Start field and
  the calendar editor's Start/End fields, so both forms accept the same
  entries and refuse the same ones with the same copy.

  ## Accepted

  Input is trimmed and case-insensitive. An hour of one or two digits,
  optionally `:MM` and then `:SS`, optionally a space, then an optional
  meridiem: `a`, `am`, `a.m.`, `p`, `pm` or `p.m.`.

    * With a meridiem the hour must be 1-12. `12am` is 00:00 and `12pm` is
      12:00.
    * Without one, hour 0 or 13-23 is read as 24-hour (`"00:30"`, `"13:00"`,
      `"13"`).

  ## Refused

    * Hour 1-12 with NO meridiem (`"01:00"`, `"1:00"`, `"12:00"`, `"9"`) is
      `{:error, :needs_meridiem}`. In en-US `"01:00"` is ambiguous, and a
      half-entered `01:00` (the AM/PM segment never picked) is exactly the
      failure this module exists to report instead of silently reading as
      1 AM.
    * Blank or `nil` is `{:error, :blank}`; callers decide whether blank is
      allowed (an ad-hoc meeting has no start).
    * Hour > 23, minute or second > 59, a meridiem on hour 0 or > 12, or
      anything else is `{:error, :invalid}`.

  `format/1` writes the unambiguous 12-hour form (`"1:00 PM"`), which
  `parse/1` reads back to the same minute.
  """

  @type reason :: :blank | :needs_meridiem | :invalid

  @pattern ~r/\A(\d{1,2})(?::(\d{2})(?::(\d{2}))?)?\s*(a|am|a\.m\.|p|pm|p\.m\.)?\z/

  @doc """
  Parse a typed time of day.

      iex> PlatformWeb.TimeEntry.parse("1:00 PM")
      {:ok, ~T[13:00:00]}

      iex> PlatformWeb.TimeEntry.parse("01:00")
      {:error, :needs_meridiem}
  """
  @spec parse(String.t() | nil) :: {:ok, Time.t()} | {:error, reason()}
  def parse(nil), do: {:error, :blank}

  def parse(input) when is_binary(input) do
    case input |> String.trim() |> String.downcase() do
      "" ->
        {:error, :blank}

      text ->
        case Regex.run(@pattern, text, capture: :all_but_first) do
          nil -> {:error, :invalid}
          parts -> build(parts)
        end
    end
  end

  def parse(_other), do: {:error, :invalid}

  defp build(parts) do
    [hour, minute, second, meridiem] =
      parts |> Kernel.++(List.duplicate("", 4 - length(parts)))

    hour = String.to_integer(hour)
    minute = to_int(minute)
    second = to_int(second)

    cond do
      hour > 23 or minute > 59 or second > 59 -> {:error, :invalid}
      meridiem == "" -> twenty_four_hour(hour, minute, second)
      hour == 0 or hour > 12 -> {:error, :invalid}
      true -> {:ok, Time.new!(to_24(hour, meridiem), minute, second)}
    end
  end

  defp twenty_four_hour(hour, minute, second) when hour == 0 or hour >= 13,
    do: {:ok, Time.new!(hour, minute, second)}

  defp twenty_four_hour(_hour, _minute, _second), do: {:error, :needs_meridiem}

  defp to_24(12, "a" <> _), do: 0
  defp to_24(hour, "a" <> _), do: hour
  defp to_24(12, "p" <> _), do: 12
  defp to_24(hour, "p" <> _), do: hour + 12

  defp to_int(""), do: 0
  defp to_int(digits), do: String.to_integer(digits)

  @doc """
  Format a time as unambiguous 12-hour text, dropping seconds.

      iex> PlatformWeb.TimeEntry.format(~T[13:00:00])
      "1:00 PM"

      iex> PlatformWeb.TimeEntry.format(~T[00:15:00])
      "12:15 AM"
  """
  @spec format(Time.t()) :: String.t()
  def format(%Time{hour: hour, minute: minute}) do
    hour12 = rem(hour + 11, 12) + 1
    meridiem = if hour < 12, do: "AM", else: "PM"
    "#{hour12}:#{String.pad_leading(Integer.to_string(minute), 2, "0")} #{meridiem}"
  end

  @doc """
  The inline error copy for a refused field, shared by every form that uses
  `parse/1`.
  """
  @spec message(:start | :end, :needs_meridiem | :invalid) :: String.t()
  def message(field, :needs_meridiem), do: "#{label(field)} is incomplete — pick AM or PM."
  def message(field, :invalid), do: "#{label(field)} isn't a time — try 1:00 PM."

  defp label(:start), do: "Start time"
  defp label(:end), do: "End time"
end
