defmodule Platform.Meetings.IcsAttendees do
  @moduledoc """
  The ORGANIZER and ATTENDEE content lines a meeting carries in iCalendar
  output, shared by the subscription feed (`Platform.Calendar.Feed` via
  `Platform.Meetings.CalendarFeed.render/2`) and the emailed iTIP invite
  (`Platform.Meetings.InviteIcs`).

  Each attendee is one line:

      ATTENDEE;CN="Name";ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;RSVP=TRUE:mailto:a@example.com

  `PARTSTAT` comes from the invite's `rsvp_status`
  (`Platform.Meetings.Invite.rsvp_partstat/1`): `invited` is `NEEDS-ACTION`,
  then `ACCEPTED`, `TENTATIVE`, `DECLINED`. Apple Calendar, Google and
  Outlook show it as the per-invitee status icon.

  A guest with no address has no `mailto:`; the line names them by the
  invite id (`urn:uuid:<id>`, RFC 5545 §3.3.3 allows any URI) so they are
  still listed by CN.

  Lines come back unfolded; the caller folds every line it emits.
  """

  @type person :: {String.t() | nil, String.t()}
  @type attendee :: %{
          required(:name) => String.t() | nil,
          required(:address) => String.t(),
          required(:partstat) => String.t()
        }

  @doc "`ORGANIZER;CN=\"<name>\":mailto:<address>`."
  @spec organizer_line(person()) :: String.t()
  def organizer_line({_name, address} = person) when is_binary(address) do
    "ORGANIZER" <> cn(person) <> ":" <> uri(address)
  end

  @doc "One `ATTENDEE` line, asked to respond (`RSVP=TRUE`)."
  @spec attendee_line(attendee()) :: String.t()
  def attendee_line(%{address: address, partstat: partstat} = attendee) do
    "ATTENDEE" <>
      cn({Map.get(attendee, :name), address}) <>
      ";ROLE=REQ-PARTICIPANT;PARTSTAT=" <> partstat <> ";RSVP=TRUE:" <> uri(address)
  end

  @doc """
  Does `address` (an email or a URI) name the same calendar user as
  `other`? Case-insensitive, ignoring a `mailto:` prefix.
  """
  @spec same_address?(String.t(), String.t()) :: boolean()
  def same_address?(address, other) when is_binary(address) and is_binary(other),
    do: normalize(address) == normalize(other)

  def same_address?(_address, _other), do: false

  # An email becomes `mailto:`; anything already carrying a scheme (the
  # `urn:uuid:` of an addressless guest) is used as is.
  defp uri(address) do
    address = String.trim(address)

    cond do
      String.contains?(address, "@") and not String.starts_with?(address, "mailto:") ->
        "mailto:" <> address

      true ->
        address
    end
  end

  defp normalize(address) do
    address |> String.trim() |> String.replace_prefix("mailto:", "") |> String.downcase()
  end

  # RFC 5545 §3.2 param-value: always quoted (so `:`, `;` and `,` in a name
  # are safe), and a DQUOTE cannot appear inside a quoted-string at all, so
  # it is dropped along with controls.
  defp cn({name, _address}) when is_binary(name) do
    case name |> String.replace(~r/["\x00-\x1F\x7F]/u, "") |> String.trim() do
      "" -> ""
      clean -> ";CN=\"" <> clean <> "\""
    end
  end

  defp cn(_person), do: ""
end
