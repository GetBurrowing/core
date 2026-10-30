defmodule Platform.ICal do
  @moduledoc "Shared RFC 5545 content-line encoding for native and meeting calendars."
  @fold_limit 75

  # RFC 5545 §3.3.5 form 2. An iCalendar DATE-TIME has no
  # fractional-second field at all, and `:utc_datetime_usec` carries
  # microseconds.
  #
  # MEASURED, not assumed: `DateTime.truncate/2` is **currently
  # unobservable** here. `%S` in the format string below renders the
  # second and nothing finer, so deleting the truncate leaves every
  # rendered byte identical — a mutation run for stage 2 removed it and
  # all 27 tests stayed green. It is kept as defence for the day someone
  # swaps this formatter for `DateTime.to_iso8601/1`, which *would* emit
  # `20260815T140000.123456Z`. Do not read its presence as something the
  # suite protects; what the suite pins is the rendered value.
  def utc_stamp(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  # RFC 5545 §3.3.11 TEXT escaping. Backslash FIRST — escaping it after
  # the others would double-escape the backslashes this function itself
  # introduced.
  def escape(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    |> String.replace(["\r\n", "\r", "\n"], "\\n")
  end

  # RFC 5545 §3.1 folding. The limit counts OCTETS, not characters and
  # not graphemes: a client unfolds by deleting the CRLF and the single
  # following space, so a fold that lands inside a multi-byte UTF-8
  # sequence yields a byte string that is no longer valid UTF-8 once
  # rejoined.
  def fold(line) do
    case take_octets(line, @fold_limit) do
      {head, ""} -> head
      {head, rest} -> [head, "\r\n", fold_continuation(rest)]
    end
  end

  defp fold_continuation(rest) do
    case take_octets(rest, @fold_limit - 1) do
      {head, ""} -> [" ", head]
      {head, more} -> [" ", head, "\r\n", fold_continuation(more)]
    end
  end

  # Longest prefix of `binary` that fits in `limit` octets without
  # splitting a codepoint, plus the remainder.
  defp take_octets(binary, limit) when byte_size(binary) <= limit, do: {binary, ""}
  defp take_octets(binary, limit), do: take_octets(binary, limit, 0, [])

  defp take_octets(rest, limit, taken, acc) do
    case String.next_codepoint(rest) do
      nil ->
        {IO.iodata_to_binary(acc), ""}

      {codepoint, tail} ->
        size = byte_size(codepoint)

        if taken + size > limit do
          {IO.iodata_to_binary(acc), rest}
        else
          take_octets(tail, limit, taken + size, [acc, codepoint])
        end
    end
  end
end
