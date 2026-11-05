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

  ## The card, in the install's branding

  One ~560px card, branded per install (task 01a1a933, the approved
  prototype 01a1a93c v2): a header with the install's icon and name, then
  the meeting. Nothing about the look is hardcoded here. `brand/2` turns the
  install's `Platform.Branding.InstallBranding` row into the name, the
  absolute URL of its 192px icon (served from the install host, never
  inlined) and the light and dark palettes `Platform.Branding.Palette.derive/2`
  yields. Light values are inlined on every element (email clients read no
  CSS variables); the dark values ride in a `prefers-color-scheme: dark`
  block with a `color-scheme` meta. Tokens used:

    * base-100: page and card surface;
    * base-content: body text;
    * muted (base-content at 55% over base-100, app.css's `--subtle`): the
      zone line, the inviter line, the footer;
    * primary / primary-content: the Join meeting button and NOTHING else;
    * edge: the card border and the footer rule;
    * the fallback link is body text, underlined.

  The time block is the signature element: the largest line after the
  title, with its zone named on the line under it. No hero, avatar or
  emoji, and no Accept/Decline buttons: the calendar client renders those
  from the `METHOD:REQUEST` part. The only image is the install icon, and
  the header names the install in text beside it.

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

  alias Platform.Branding
  alias Platform.Branding.InstallBranding
  alias Platform.Branding.Palette
  alias Platform.Meetings.InviteIcs
  alias Platform.Meetings.Meeting

  @kinds [:invitation, :cancelled, :updated]

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
          optional(:guest_url) => String.t() | nil,
          optional(:brand) => brand()
        }
  @type palette :: %{
          base_100: String.t(),
          base_content: String.t(),
          edge: String.t(),
          primary: String.t(),
          primary_content: String.t(),
          link: String.t(),
          muted: String.t()
        }
  @type brand :: %{
          app_name: String.t() | nil,
          icon_url: String.t() | nil,
          light: palette(),
          dark: palette()
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
  for join links (`app_url`, `guest_url`), and `brand` — the install's
  name, icon and palettes from `brand/2`.
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
      html_body: html_body(facts, Map.get(ctx, :brand) || default_brand()),
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
  #
  # Every colour below is a token of the install's palette (`brand/2`); the
  # light value is inlined on the element and the dark value is applied by
  # the `prefers-color-scheme: dark` block through the element's class.
  # Clients that strip <style> keep the light card, which reads on its own.

  defp html_body(facts, brand) do
    l = brand.light
    d = brand.dark

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="light dark">
    <meta name="supported-color-schemes" content="light dark">
    <title>#{h(facts.title)}</title>
    <style>
    @media (prefers-color-scheme: dark) {
      .im-page, .im-card { background-color: #{d.base_100} !important; }
      .im-card { border-color: #{d.edge} !important; }
      .im-ink { color: #{d.base_content} !important; }
      .im-muted { color: #{d.muted} !important; }
      .im-rule { border-top-color: #{d.edge} !important; }
      .im-button { background-color: #{d.primary} !important; }
      .im-button-text { color: #{d.primary_content} !important; }
      .im-link { color: #{d.link} !important; }
    }
    </style>
    </head>
    <body class="im-page" style="margin:0;padding:0;background-color:#{l.base_100};">
    <table role="presentation" class="im-page" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#{l.base_100};">
    <tr><td align="center" style="padding:24px 12px;">
    <table role="presentation" class="im-card" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;background-color:#{l.base_100};border:1px solid #{l.edge};border-radius:12px;">
    <tr><td style="padding:24px 28px 0 28px;font-family:#{@font};">
    #{header_html(brand)}
    </td></tr>
    <tr><td style="padding:20px 28px 24px 28px;font-family:#{@font};color:#{l.base_content};">
    <h1 class="im-ink" style="margin:0 0 20px 0;font-size:22px;line-height:28px;font-weight:600;color:#{l.base_content};">#{h(facts.title)}</h1>
    #{changed_html(facts, l)}<p class="im-ink" style="margin:0;font-size:19px;line-height:26px;font-weight:600;color:#{l.base_content};">#{h(time_text(facts))}</p>
    #{zone_html(facts, l)}<p class="im-muted" style="margin:20px 0 0 0;font-size:15px;line-height:22px;color:#{l.muted};">#{h(inviter_line(facts))}</p>
    #{action_html(facts, l)}
    <hr class="im-rule" style="border:0;border-top:1px solid #{l.edge};margin:24px 0 16px 0;">
    <p class="im-muted" style="margin:0;font-size:13px;line-height:20px;color:#{l.muted};">#{h(sent_from(facts))}<br>#{h(reply_line(facts))}</p>
    </td></tr>
    </table>
    </td></tr>
    </table>
    </body>
    </html>
    """
  end

  # Install icon and name. The icon is referenced from the install host,
  # never inlined, and the name follows it as text so the header reads with
  # images off.
  defp header_html(%{app_name: nil, icon_url: nil}), do: ""

  defp header_html(brand) do
    icon =
      case brand.icon_url do
        url when is_binary(url) and url != "" ->
          ~s(<img src="#{h(url)}" width="32" height="32" alt="" style="display:block;width:32px;height:32px;border:0;border-radius:8px;">)

        _ ->
          ""
      end

    """
    <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
    <td style="padding:0 10px 0 0;vertical-align:middle;">#{icon}</td>
    <td class="im-ink" style="vertical-align:middle;font-size:16px;line-height:20px;font-weight:600;color:#{brand.light.base_content};">#{h(brand.app_name)}</td>
    </tr></table>\
    """
  end

  defp changed_html(%{kind: :updated}, l) do
    ~s(<p class="im-ink" style="margin:0 0 4px 0;font-size:15px;line-height:22px;font-weight:600;color:#{l.base_content};">) <>
      h(@changed_line) <> "</p>\n"
  end

  defp changed_html(_facts, _l), do: ""

  defp zone_html(%{zone_line: nil}, _l), do: ""

  defp zone_html(%{zone_line: line}, l) do
    ~s(<p class="im-muted" style="margin:2px 0 0 0;font-size:15px;line-height:22px;color:#{l.muted};">) <>
      h(line) <> "</p>\n"
  end

  defp action_html(%{kind: :cancelled}, l) do
    ~s(<p class="im-ink" style="margin:24px 0 0 0;font-size:16px;line-height:24px;font-weight:600;color:#{l.base_content};">) <>
      h(@cancelled_line) <> "</p>"
  end

  defp action_html(%{join_url: nil}, _l), do: ""

  # The button's fill sits on the cell, not the link, so it renders in
  # clients that ignore padding on <a>. It is the only use of the primary
  # colour in the email.
  defp action_html(%{join_url: url}, l) do
    """
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:24px 0 0 0;">
    <tr><td class="im-button" style="background-color:#{l.primary};border-radius:9px;">
    <a class="im-button-text" href="#{h(url)}" style="display:inline-block;padding:12px 22px;font-family:#{@font};font-size:16px;line-height:20px;font-weight:600;color:#{l.primary_content};text-decoration:none;border-radius:9px;">Join meeting</a>
    </td></tr>
    </table>
    <p class="im-ink" style="margin:12px 0 0 0;font-size:15px;line-height:22px;color:#{l.base_content};word-break:break-all;">or open: <a class="im-link" href="#{h(url)}" style="color:#{l.link};">#{h(url)}</a></p>\
    """
  end

  # ── Branding ─────────────────────────────────────────────────────────────

  @doc """
  The install branding `build/4` paints with, from an
  `Platform.Branding.InstallBranding` row: its `app_name`, its 192px icon
  made absolute against `base_url` (the install host), and the light and
  dark palettes `Platform.Branding.Palette.derive/2` yields for its colours.
  Pure: the caller reads the row (`Platform.Branding.get/0`).
  """
  @spec brand(InstallBranding.t(), String.t() | nil) :: brand()
  def brand(%InstallBranding{} = branding, base_url) do
    colours = Branding.app_colors(branding)

    %{
      app_name: branding.app_name,
      icon_url: absolute(base_url, Branding.icon_url(branding, :icon_192)),
      light: tokens(Palette.derive(:light, colours.light)),
      dark: tokens(Palette.derive(:dark, colours.dark))
    }
  end

  # With no branding passed, the shipped palette and no name or icon.
  defp default_brand do
    defaults = Palette.suite_defaults()

    %{
      app_name: nil,
      icon_url: nil,
      light: tokens(Palette.derive(:light, defaults.light)),
      dark: tokens(Palette.derive(:dark, defaults.dark))
    }
  end

  defp tokens(derived) do
    surface = derived["--color-base-100"]
    content = derived["--color-base-content"]

    %{
      base_100: surface,
      base_content: content,
      edge: derived["--edge"],
      primary: derived["--color-primary"],
      primary_content: derived["--color-primary-content"],
      # The fallback link is body text, underlined: the primary colour is
      # reserved for the one button.
      link: content,
      # The secondary text tier: body text at 55% over the surface, the
      # same mix app.css's --subtle declares, flattened to hex for email.
      muted: mix(content, surface, 0.55)
    }
  end

  defp mix(fg, bg, weight) do
    [fr, fg_, fb] = rgb(fg)
    [br, bg_, bb] = rgb(bg)

    [
      fr * weight + br * (1 - weight),
      fg_ * weight + bg_ * (1 - weight),
      fb * weight + bb * (1 - weight)
    ]
    |> Enum.map(&(&1 |> round() |> Integer.to_string(16) |> String.pad_leading(2, "0")))
    |> Enum.join()
    |> String.downcase()
    |> then(&("#" <> &1))
  end

  defp rgb("#" <> <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>>),
    do: Enum.map([r, g, b], &String.to_integer(&1, 16))

  defp h(nil), do: ""
  defp h(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
