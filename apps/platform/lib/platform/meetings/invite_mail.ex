defmodule Platform.Meetings.InviteMail do
  @moduledoc """
  Builds the email a person gets when they are invited to a meeting, when
  it is cancelled, and when its time changes (task 01a1a933 stage 2;
  design direction canvas 01a1a936).

  `build/4` is pure: everything it shows arrives in its arguments, so the
  caller (stage 3's mailer) reads the org row, the inviter and the hosts and
  this module never touches `Repo` or app config. It returns the draft
  fields `Platform.Mail.Drafts.create_system/2` takes:
  `%{subject, body, html_body, calendar_method, calendar_ics}`.

  ## The card

  One ~560px light card, inline hex only (email clients read no CSS
  variables and ignore our dark theme). Every colour is a light-theme token
  from `assets/css/app.css`:

    * `#fbfaf9` base-100, page and card surface; also primary-content, the
      button text;
    * `#000000` base-content, body text;
    * `#635b53` secondary, the zone line, the inviter line, the footer;
    * `#ad4b07` primary, the Join meeting button fill and NOTHING else;
    * `#d9d3c9` the edge slot, the card border and the footer rule.

  The time block is the signature element: the largest line after the
  title, with its zone named on the line under it. No logo, image, avatar
  or emoji, and no Accept/Decline buttons: the calendar client renders
  those from the `METHOD:REQUEST` part.

  ## Time zone

  Resolved in this order:

    1. the invitee's own `preferences["time_zone"]`, when it is a valid IANA
       zone — no setting writes it yet, but reading it here means one will
       work without touching this module; the zone line then says
       `(your time zone)`;
    2. the inviter's zone, `ctx.inviter.time_zone` (the zone of the
       LiveView that sent the invite);
    3. UTC.

  The calendar part carries UTC, so the calendar client shows the
  invitee's own local time whichever zone the body used.

  ## Join URL

  A guest (recipient with a `short_code`) gets `<guest_url>/g/<code>`; a
  member gets `<app_url>/meetings/<slug>`. Both bases come from `ctx`;
  there is no host in this module. With no base for the recipient there is
  no button and no fallback line.

  ## Unscheduled meetings

  An ad-hoc meeting has no time to put on a calendar: no calendar part
  (`calendar_method: nil`) and the time block reads `Happening now`.

  Every interpolated value is HTML-escaped: meeting names are user input.
  """

  alias Platform.Meetings.InviteIcs
  alias Platform.Meetings.Meeting

  @kinds [:invitation, :cancelled, :updated]

  # Light-theme tokens, assets/css/app.css. See the moduledoc.
  @surface "#fbfaf9"
  @ink "#000000"
  @secondary "#635b53"
  @primary "#ad4b07"
  @on_primary "#fbfaf9"
  @edge "#d9d3c9"
  @font "'Public Sans', system-ui, -apple-system, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"

  @utc "Etc/UTC"

  @type kind :: :invitation | :cancelled | :updated
  @type recipient :: %{
          required(:email) => String.t(),
          optional(:name) => String.t() | nil,
          optional(:short_code) => String.t() | nil,
          optional(:preferences) => map() | nil
        }
  @type ctx :: %{
          required(:organizer) => {String.t() | nil, String.t()},
          optional(:inviter) => %{
            optional(:name) => String.t(),
            optional(:time_zone) => String.t()
          },
          optional(:org_name) => String.t() | nil,
          optional(:app_url) => String.t() | nil,
          optional(:guest_url) => String.t() | nil
        }
  @type built :: %{
          subject: String.t(),
          body: String.t(),
          html_body: String.t(),
          calendar_method: String.t() | nil,
          calendar_ics: String.t() | nil
        }

  @doc "The kinds `build/4` accepts."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Build the `kind` email about `meeting` for `recipient`.

  `ctx` carries the sending identity (`organizer: {display_name, address}`,
  the address the calendar part names as ORGANIZER), the inviter
  (`%{name, time_zone}`), the org's display name, and the absolute bases
  for join links (`app_url`, `guest_url`).
  """
  @spec build(kind(), Meeting.t(), recipient(), ctx()) :: built()
  def build(kind, %Meeting{} = meeting, recipient, ctx) when kind in @kinds do
    {zone, zone_source} = resolve_zone(recipient, ctx)
    join_url = join_url(meeting, recipient, ctx)
    when_ = time_block(meeting, zone)
    {calendar_method, calendar_ics} = calendar(kind, meeting, recipient, ctx, join_url)

    facts = %{
      kind: kind,
      title: single_line(meeting.name),
      when: when_,
      zone_line: zone_line(when_, zone, zone_source),
      inviter: inviter_name(ctx),
      org_name: org_name(ctx),
      join_url: join_url
    }

    %{
      subject: subject(facts),
      body: text_body(facts),
      html_body: html_body(facts),
      calendar_method: calendar_method,
      calendar_ics: calendar_ics
    }
  end

  # ── Calendar part ────────────────────────────────────────────────────────

  defp calendar(kind, meeting, recipient, ctx, join_url) do
    method = if kind == :cancelled, do: :cancel, else: :request

    parties = %{
      organizer: ctx.organizer,
      attendee: {Map.get(recipient, :name), recipient.email},
      location: join_url
    }

    case InviteIcs.render(meeting, method, parties) do
      {:ok, ics} -> {if(method == :cancel, do: "CANCEL", else: "REQUEST"), ics}
      {:error, :unscheduled} -> {nil, nil}
    end
  end

  # ── Zone and time ────────────────────────────────────────────────────────

  @doc false
  # Public for the tests: `{zone, :invitee | :inviter | :default}`.
  @spec resolve_zone(recipient(), ctx()) :: {String.t(), :invitee | :inviter | :default}
  def resolve_zone(recipient, ctx) do
    invitee = recipient |> Map.get(:preferences) |> preference_zone()
    inviter = ctx |> Map.get(:inviter) |> inviter_zone()

    cond do
      valid_zone?(invitee) -> {invitee, :invitee}
      valid_zone?(inviter) -> {inviter, :inviter}
      true -> {@utc, :default}
    end
  end

  defp preference_zone(%{"time_zone" => zone}), do: zone
  defp preference_zone(_), do: nil

  defp inviter_zone(%{time_zone: zone}), do: zone
  defp inviter_zone(_), do: nil

  defp valid_zone?(zone) when is_binary(zone) and zone != "" do
    match?({:ok, _}, DateTime.shift_zone(~U[2026-01-01 00:00:00Z], zone))
  end

  defp valid_zone?(_zone), do: false

  defp time_block(
         %Meeting{scheduled_start_at: %DateTime{} = s, scheduled_end_at: %DateTime{} = e},
         zone
       ) do
    start = DateTime.shift_zone!(s, zone)
    finish = DateTime.shift_zone!(e, zone)
    %{start: start, finish: finish, line: range_line(start, finish)}
  end

  defp time_block(%Meeting{}, _zone), do: nil

  defp range_line(start, finish) do
    if DateTime.to_date(start) == DateTime.to_date(finish) do
      day(start) <> " - " <> clock_range(start, finish)
    else
      day(start) <> " - " <> clock(start) <> " to " <> day(finish) <> " - " <> clock(finish)
    end
  end

  defp clock_range(start, finish) do
    if meridiem(start) == meridiem(finish) do
      bare_clock(start) <> "-" <> clock(finish)
    else
      clock(start) <> "-" <> clock(finish)
    end
  end

  defp day(dt), do: Calendar.strftime(dt, "%a %-d %b")
  defp clock(dt), do: bare_clock(dt) <> " " <> meridiem(dt)
  defp bare_clock(dt), do: Calendar.strftime(dt, "%-I:%M")
  defp meridiem(dt), do: Calendar.strftime(dt, "%p")

  defp zone_line(nil, _zone, _source), do: nil
  defp zone_line(_when, @utc, _source), do: "UTC"

  defp zone_line(%{start: start}, zone, source) do
    named = zone <> ", " <> start.zone_abbr
    if source == :invitee, do: named <> " (your time zone)", else: named
  end

  # ── Who and where ────────────────────────────────────────────────────────

  defp join_url(%Meeting{} = meeting, recipient, ctx) do
    case Map.get(recipient, :short_code) do
      code when is_binary(code) and code != "" ->
        absolute(Map.get(ctx, :guest_url), "/g/" <> code)

      _ ->
        absolute(Map.get(ctx, :app_url), "/meetings/" <> (meeting.slug || ""))
    end
  end

  defp absolute(base, path) when is_binary(base) and base != "" do
    String.trim_trailing(base, "/") <> path
  end

  defp absolute(_base, _path), do: nil

  defp inviter_name(ctx) do
    case ctx |> Map.get(:inviter) |> then(&(&1 && Map.get(&1, :name))) do
      name when is_binary(name) and name != "" -> single_line(name)
      _ -> nil
    end
  end

  defp org_name(ctx) do
    case Map.get(ctx, :org_name) do
      name when is_binary(name) and name != "" -> single_line(name)
      _ -> nil
    end
  end

  defp single_line(nil), do: ""
  defp single_line(value), do: value |> String.replace(~r/[\r\n\t]+/, " ") |> String.trim()

  # ── Subject ──────────────────────────────────────────────────────────────

  defp subject(%{kind: :cancelled, title: title}), do: "Cancelled: " <> title
  defp subject(%{kind: :updated, title: title}), do: "Updated: " <> title
  defp subject(%{kind: :invitation, title: title, when: nil}), do: "Invitation: " <> title

  defp subject(%{kind: :invitation, title: title, when: %{start: start}}) do
    "Invitation: " <> title <> " - " <> day(start) <> ", " <> clock(start) <> " " <> abbr(start)
  end

  defp abbr(%DateTime{time_zone: @utc}), do: "UTC"
  defp abbr(%DateTime{zone_abbr: abbr}), do: abbr

  # ── Copy ─────────────────────────────────────────────────────────────────

  defp time_text(%{when: nil}), do: "Happening now"
  defp time_text(%{when: %{line: line}}), do: line

  defp inviter_line(%{inviter: nil}), do: "You are invited"
  defp inviter_line(%{inviter: name}), do: name <> " invited you"

  defp sent_from(%{org_name: nil}), do: "Sent from Burrow."
  defp sent_from(%{org_name: org}), do: "Sent from " <> org <> " on Burrow."

  defp reply_line(%{inviter: nil}), do: "Reply to reach the organizer."
  defp reply_line(%{inviter: name}), do: "Reply to reach " <> name <> "."

  @cancelled_line "This meeting was cancelled."
  @changed_line "Time changed"

  # ── Plain text ───────────────────────────────────────────────────────────

  defp text_body(facts) do
    [
      facts.title,
      "",
      if(facts.kind == :updated, do: @changed_line),
      time_text(facts),
      facts.zone_line,
      "",
      inviter_line(facts) <> ".",
      "",
      action_text(facts),
      "",
      "--",
      sent_from(facts),
      reply_line(facts)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp action_text(%{kind: :cancelled}), do: @cancelled_line
  defp action_text(%{join_url: nil}), do: nil
  defp action_text(%{join_url: url}), do: "Join meeting: " <> url

  # ── HTML ─────────────────────────────────────────────────────────────────

  defp html_body(facts) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="light">
    <title>#{h(facts.title)}</title>
    </head>
    <body style="margin:0;padding:0;background-color:#{@surface};">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#{@surface};">
    <tr><td align="center" style="padding:24px 12px;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;background-color:#{@surface};border:1px solid #{@edge};border-radius:12px;">
    <tr><td style="padding:28px 28px 24px 28px;font-family:#{@font};color:#{@ink};">
    <h1 style="margin:0 0 20px 0;font-size:22px;line-height:28px;font-weight:600;color:#{@ink};">#{h(facts.title)}</h1>
    #{changed_html(facts)}<p style="margin:0;font-size:19px;line-height:26px;font-weight:600;color:#{@ink};">#{h(time_text(facts))}</p>
    #{zone_html(facts)}<p style="margin:20px 0 0 0;font-size:15px;line-height:22px;color:#{@secondary};">#{h(inviter_line(facts))}</p>
    #{action_html(facts)}
    <hr style="border:0;border-top:1px solid #{@edge};margin:24px 0 16px 0;">
    <p style="margin:0;font-size:13px;line-height:20px;color:#{@secondary};">#{h(sent_from(facts))}<br>#{h(reply_line(facts))}</p>
    </td></tr>
    </table>
    </td></tr>
    </table>
    </body>
    </html>
    """
  end

  defp changed_html(%{kind: :updated}) do
    ~s(<p style="margin:0 0 4px 0;font-size:15px;line-height:22px;font-weight:600;color:#{@ink};">) <>
      h(@changed_line) <> "</p>\n"
  end

  defp changed_html(_facts), do: ""

  defp zone_html(%{zone_line: nil}), do: ""

  defp zone_html(%{zone_line: line}) do
    ~s(<p style="margin:2px 0 0 0;font-size:15px;line-height:22px;color:#{@secondary};">) <>
      h(line) <> "</p>\n"
  end

  defp action_html(%{kind: :cancelled}) do
    ~s(<p style="margin:24px 0 0 0;font-size:16px;line-height:24px;font-weight:600;color:#{@ink};">) <>
      h(@cancelled_line) <> "</p>"
  end

  defp action_html(%{join_url: nil}), do: ""

  # The button's fill sits on the cell, not the link, so it renders in
  # clients that ignore padding on <a>. It is the only #ad4b07 in the email.
  defp action_html(%{join_url: url}) do
    """
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:24px 0 0 0;">
    <tr><td style="background-color:#{@primary};border-radius:9px;">
    <a href="#{h(url)}" style="display:inline-block;padding:12px 22px;font-family:#{@font};font-size:16px;line-height:20px;font-weight:600;color:#{@on_primary};text-decoration:none;border-radius:9px;">Join meeting</a>
    </td></tr>
    </table>
    <p style="margin:12px 0 0 0;font-size:15px;line-height:22px;color:#{@ink};word-break:break-all;">or open: <a href="#{h(url)}" style="color:#{@ink};">#{h(url)}</a></p>\
    """
  end

  defp h(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
