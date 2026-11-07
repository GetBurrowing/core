defmodule PlatformWeb.Components.SupportAccessComponents do
  @moduledoc """
  The owner-facing surfaces of vendor support access (task 01a1b362 stage 2;
  design canvas 01a1b362-e9b9): the active-session banner the shell draws on
  every page, the member-list marker, and the visit rows of Settings →
  Support. The Support card itself lives in `PlatformWeb.SettingsLive`, which
  owns the existing switch.

  Every string comes from `PlatformWeb.SupportAccessCopy`.

  ## Colour

  Support presence is information, not an error: the banner and the marker
  are `info` (teal), never primary or warning. In the visit list only the
  status dot is coloured (`success` for a live session, `error` for a refused
  request, neutral otherwise) and it is an aria-hidden icon next to body-text
  words (meeting_palette_guard R3's icon-only pattern).

  ## Times

  End times and visit timestamps are mono and in the viewer's zone (the
  socket's `timezone` connect param). Users have no stored zone. Without one
  (the dead render, an unknown zone) a time is UTC and says so.
  """
  use Phoenix.Component

  alias Platform.SupportAccess.Session
  alias PlatformWeb.SupportAccessCopy, as: Copy

  # ── Time ─────────────────────────────────────────────────────────────

  @doc "\"01:40\" in `zone`, or \"01:40 UTC\" without a usable zone."
  @spec clock(DateTime.t(), String.t() | nil) :: String.t()
  def clock(%DateTime{} = at, zone) do
    case local(at, zone) do
      {local, false} -> Calendar.strftime(local, "%H:%M")
      {utc, true} -> Calendar.strftime(utc, "%H:%M") <> " UTC"
    end
  end

  @doc "\"6 Nov 22:10–23:40\" (\"–\" for a session still running)."
  @spec span(DateTime.t(), DateTime.t() | nil, String.t() | nil) :: String.t()
  def span(%DateTime{} = from, to, zone) do
    {local_from, utc?} = local(from, zone)
    head = Calendar.strftime(local_from, "%-d %b %H:%M")

    tail =
      case to do
        %DateTime{} -> Calendar.strftime(elem(local(to, zone), 0), "%H:%M")
        nil -> ""
      end

    head <> "–" <> tail <> if(utc?, do: " UTC", else: "")
  end

  @doc "\"6 Nov 22:10\"."
  @spec stamp(DateTime.t(), String.t() | nil) :: String.t()
  def stamp(%DateTime{} = at, zone) do
    {local_at, utc?} = local(at, zone)
    Calendar.strftime(local_at, "%-d %b %H:%M") <> if(utc?, do: " UTC", else: "")
  end

  defp local(at, zone) do
    case zone && DateTime.shift_zone(at, zone) do
      {:ok, local} -> {local, false}
      _ -> {at, true}
    end
  end

  # ── Banner ───────────────────────────────────────────────────────────

  @doc """
  The active-session banner: a slim info strip, shown only while a session
  is live (`sessions` non-empty) and NOT dismissible: it is how the owner
  knows. "Details" goes to Settings → Support, for a viewer who can see that
  card (`details?`).

  With an admin session live it says "signed in"; with only a repair session
  it says "working on your server". The time is the latest end of any live
  session.
  """
  attr(:sessions, :list, required: true)
  attr(:zone, :string, default: nil)
  attr(:details?, :boolean, default: false)

  def support_banner(assigns) do
    assigns =
      case assigns.sessions do
        [] ->
          assign(assigns, :until, nil)

        sessions ->
          {lead, trail} =
            if Enum.any?(sessions, &(&1.kind == "admin")),
              do: Copy.banner_admin(),
              else: Copy.banner_repair()

          until = sessions |> Enum.map(& &1.not_after) |> Enum.max(DateTime)

          assigns
          |> assign(:until, until)
          |> assign(:lead, lead)
          |> assign(:trail, trail)
      end

    ~H"""
    <div
      :if={@until}
      id="support-banner"
      role="status"
      data-role="support-banner"
      class="flex shrink-0 items-center gap-2 bg-info px-4 py-1.5 text-[13px] text-info-content"
    >
      <span class="hero-information-circle size-4 shrink-0" aria-hidden="true"></span>
      <p class="min-w-0 flex-1">
        {@lead}<span class="font-mono" data-role="support-banner-until">{clock(@until, @zone)}</span>{@trail}
      </p>
      <.link
        :if={@details?}
        navigate="/settings#support"
        data-role="support-banner-details"
        class="shrink-0 font-semibold underline underline-offset-2 focus-visible-ring"
      >
        {Copy.banner_details()}
      </.link>
    </div>
    """
  end

  # ── Member-list marker ───────────────────────────────────────────────

  @doc """
  The marker after a support user's name. It is `shrink-0`, so the name (the
  caller's `min-w-0 truncate`) gives way and the marker is never cut.
  """
  attr(:id, :string, default: nil)

  def support_marker(assigns) do
    ~H"""
    <span
      id={@id}
      data-role="support-marker"
      class="inline-flex shrink-0 items-center rounded-full bg-info px-1.5 text-xs font-semibold leading-5 text-info-content"
    >
      {Copy.marker()}
    </span>
    """
  end

  @doc "\"leaves at 01:40\", muted, for a support user's row while it is live."
  attr(:at, :any, required: true)
  attr(:zone, :string, default: nil)
  attr(:class, :any, default: nil)

  def support_leaves_at(assigns) do
    ~H"""
    <span :if={@at} data-role="support-leaves-at" class={["text-subtle", @class]}>
      {Copy.leaves_at()}<span class="font-mono">{clock(@at, @zone)}</span>
    </span>
    """
  end

  # ── Visit rows ───────────────────────────────────────────────────────

  @doc """
  Recent visits for the Support card: sessions and refused requests merged,
  newest first, at most `limit`. Each entry is a map the `visit_row/1`
  component renders.
  """
  @spec visits([Session.t()], [map()], DateTime.t(), pos_integer()) :: [map()]
  def visits(sessions, refusals, now \\ DateTime.utc_now(), limit \\ 5) do
    session_rows =
      Enum.map(sessions, fn s ->
        active? = Session.active?(s, now)

        %{
          id: "session-" <> s.id,
          at: s.not_before,
          from: s.not_before,
          to: if(active?, do: s.not_after, else: s.ended_at || s.not_after),
          who: s.operator_name,
          kind: s.kind,
          state: if(active?, do: :active, else: :ended),
          status: if(active?, do: Copy.status_active(), else: Copy.end_reason_label(s.end_reason))
        }
      end)

    refusal_rows =
      Enum.map(refusals, fn e ->
        m = e.metadata || %{}

        %{
          id: "refusal-#{e.id}",
          at: e.inserted_at,
          from: e.inserted_at,
          to: nil,
          who: m["operator_name"] || Copy.who(),
          kind: m["kind"],
          state: :refused,
          status: Copy.refused_label(m["reason"])
        }
      end)

    (session_rows ++ refusal_rows)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  attr(:visit, :map, required: true)
  attr(:zone, :string, default: nil)

  def visit_row(assigns) do
    ~H"""
    <li
      id={"support-visit-" <> @visit.id}
      data-role="support-visit"
      data-state={@visit.state}
      class="flex items-start gap-2 py-1.5 text-[13px] text-base-content"
    >
      <span
        aria-hidden="true"
        class={["mt-[5px] inline-block size-2 shrink-0 rounded-full", dot_class(@visit.state)]}
      >
      </span>
      <span class="min-w-0 flex-1">
        <span class="font-mono" data-role="support-visit-time">
          {if @visit.state == :refused,
            do: stamp(@visit.from, @zone),
            else: span(@visit.from, @visit.to, @zone)}
        </span>
        <span>
          {@visit.who} · {Copy.kind_label(@visit.kind)} · {@visit.status}
        </span>
      </span>
    </li>
    """
  end

  defp dot_class(:active), do: "bg-success"
  defp dot_class(:refused), do: "bg-error"
  defp dot_class(_), do: "bg-subtle"

  attr(:event, :map, required: true)
  attr(:zone, :string, default: nil)

  def activity_row(assigns) do
    ~H"""
    <li
      id={"support-activity-#{@event.id}"}
      data-role="support-activity"
      class="flex flex-col gap-0.5 px-[18px] py-2 text-[13px] text-base-content"
    >
      <span class="font-mono text-subtle">{stamp(@event.inserted_at, @zone)}</span>
      <span>{Copy.activity_line(@event)}</span>
      <span
        :if={detail(@event)}
        class="min-w-0 break-all font-mono text-xs text-subtle"
      >
        {detail(@event)}
      </span>
    </li>
    """
  end

  defp detail(%{event_type: "support.shell_command", metadata: %{"command" => c}})
       when is_binary(c),
       do: c

  defp detail(%{event_type: "support.action", metadata: %{"route" => r}}) when is_binary(r),
    do: r

  defp detail(%{event_type: "support.action", metadata: %{"view" => v, "event" => e}}),
    do: "#{v} · #{e}"

  defp detail(_), do: nil
end
