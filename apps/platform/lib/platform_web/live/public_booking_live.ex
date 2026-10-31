defmodule PlatformWeb.PublicBookingLive do
  @moduledoc """
  `/book/:token`: the guest booking page, rebuilt to prototype `01a178d2` v4
  `booking.html` / `booking.js` (task 01a18d9f stage 3).

  One card: the host column, a month picker whose open days come from
  `BookingLinks.open_days/2`, the day's times from `BookingLinks.slots/2`,
  then the guest form and the done screen. Booking goes through PR #51's
  `BookingLinks.book/3` unchanged; every load is still bounded by the
  per-IP `BookingRateLimit` check.
  """
  use Phoenix.LiveView, log: false
  import PlatformWeb.CoreComponents, only: [icon: 1]
  use PlatformWeb, :verified_routes
  alias Platform.Calendar.{BookingLinks, BookingRateLimit}

  @unavailable "Availability cannot be confirmed right now. Try again later or contact the organizer."

  def mount(%{"token" => token}, _, socket) do
    peer = get_connect_info(socket, :peer_data)
    ip = if peer, do: peer.address, else: :http

    {policy, zone} =
      case BookingLinks.public_policy(token) do
        {:ok, policy} -> {policy, policy.time_zone}
        _ -> {nil, "Etc/UTC"}
      end

    today = DateTime.utc_now() |> DateTime.shift_zone!(zone) |> DateTime.to_date()

    {:ok,
     socket
     |> assign(
       page_title: if(policy, do: policy.title, else: "Book a time"),
       token: token,
       ip: ip,
       policy: policy,
       zone: zone,
       today: today,
       month: Date.beginning_of_month(today),
       open: %{},
       day: nil,
       slots: [],
       slot: nil,
       step: :pick,
       guest: %{"name" => "", "email" => "", "notes" => ""},
       errors: %{},
       error: if(policy, do: nil, else: @unavailable),
       receipt: nil,
       key: new_key()
     )
     |> load_month()}
  end

  def handle_event("month", %{"direction" => direction}, socket) do
    month = socket.assigns.month

    month =
      if direction == "previous",
        do:
          Enum.max(
            [
              Date.beginning_of_month(Date.add(month, -1)),
              Date.beginning_of_month(socket.assigns.today)
            ],
            Date
          ),
        else: Date.add(month, Date.days_in_month(month))

    {:noreply, socket |> assign(month: month) |> load_month()}
  end

  def handle_event("pick", %{"date" => date}, socket) do
    case Date.from_iso8601(date) do
      {:ok, date} -> {:noreply, socket |> assign(day: date, slot: nil) |> load_day()}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("slot", %{"start" => start}, socket) do
    case Enum.find(socket.assigns.slots, &(DateTime.to_iso8601(&1.starts_at) == start)) do
      nil -> {:noreply, socket}
      slot -> {:noreply, assign(socket, slot: slot, step: :form, errors: %{}, error: nil)}
    end
  end

  def handle_event("keep", params, socket), do: {:noreply, keep(socket, params)}

  def handle_event("change", params, socket),
    do: {:noreply, socket |> keep(params) |> assign(step: :pick, errors: %{})}

  def handle_event("again", _, socket) do
    {:noreply,
     socket
     |> assign(
       day: nil,
       slots: [],
       slot: nil,
       step: :pick,
       receipt: nil,
       errors: %{},
       error: nil,
       guest: %{"name" => "", "email" => "", "notes" => ""},
       key: new_key()
     )
     |> load_month()}
  end

  # booking.js `#confirm`: name, then email (required for a meeting link),
  # then email shape; then PR #51's BookingLinks.book/3.
  def handle_event("confirm", params, socket) do
    socket = keep(socket, params)
    %{"name" => name, "email" => email} = socket.assigns.guest
    meeting? = socket.assigns.policy && socket.assigns.policy.create_meeting

    errors =
      %{}
      |> then(&if(name == "", do: Map.put(&1, :name, "Add your name."), else: &1))
      |> then(fn errors ->
        cond do
          meeting? and email == "" ->
            Map.put(
              errors,
              :email,
              "Email is required for a meeting booking: the invite goes there."
            )

          email != "" and not Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/, email) ->
            Map.put(errors, :email, "That email doesn’t look right.")

          true ->
            errors
        end
      end)

    if errors != %{} do
      {:noreply, assign(socket, errors: errors)}
    else
      result =
        with :ok <- check_rate(socket),
             do:
               BookingLinks.book(
                 socket.assigns.token,
                 %{
                   "name" => name,
                   "email" => email,
                   "starts_at" => DateTime.to_iso8601(socket.assigns.slot.starts_at)
                 },
                 socket.assigns.key
               )

      case result do
        {:ok, receipt} ->
          {:noreply, assign(socket, receipt: receipt, step: :done, errors: %{}, error: nil)}

        _ ->
          {:noreply,
           socket
           |> assign(
             step: :pick,
             slot: nil,
             error:
               "This time could not be booked. Check your details and choose an available time. Meeting bookings require an email address."
           )
           |> load_day()}
      end
    end
  end

  defp keep(socket, %{"guest" => guest}) when is_map(guest) do
    guest =
      Map.merge(
        socket.assigns.guest,
        guest |> Map.take(~w(name email notes)) |> Map.new(fn {k, v} -> {k, String.trim(v)} end)
      )

    assign(socket, :guest, guest)
  end

  defp keep(socket, _), do: socket

  defp check_rate(socket) do
    if connected?(socket), do: BookingRateLimit.check({:ip, socket.assigns.ip}, 1, 60), else: :ok
  end

  defp load_month(%{assigns: %{policy: nil}} = socket), do: socket

  defp load_month(socket) do
    with :ok <- check_rate(socket),
         {:ok, open} <- BookingLinks.open_days(socket.assigns.token, socket.assigns.month) do
      assign(socket, open: open, error: nil)
    else
      _ -> assign(socket, open: %{}, error: @unavailable)
    end
  end

  defp load_day(%{assigns: %{day: nil}} = socket), do: assign(socket, :slots, [])

  defp load_day(socket) do
    with :ok <- check_rate(socket),
         {:ok, slots} <- BookingLinks.slots(socket.assigns.token, socket.assigns.day) do
      assign(socket, slots: slots)
    else
      _ -> assign(socket, slots: [], error: @unavailable)
    end
  end

  defp new_key, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  defp local(at, zone), do: DateTime.shift_zone!(at, zone)
  defp hm(at, zone), do: at |> local(zone) |> Calendar.strftime("%H:%M")

  @doc "`Monday, 26 October` (booking.js `dl`)."
  def long_day(date), do: Calendar.strftime(date, "%A, %-d %B")

  defp zone_label(zone) do
    abbr = DateTime.utc_now() |> DateTime.shift_zone!(zone) |> Map.get(:zone_abbr)
    if abbr in [nil, ""] or String.match?(abbr, ~r/^[+-]/), do: zone, else: "#{zone} (#{abbr})"
  end

  defp first_name(nil), do: "the organizer"
  defp first_name(name), do: name |> String.split() |> List.first() || name

  defp initial(nil), do: "?"
  defp initial(name), do: name |> String.first() |> String.upcase()

  # PR #51 exposes no .ics for a booking, so "Add to my calendar" downloads a
  # one-event file built here from the receipt.
  defp ics(receipt, policy) do
    stamp = fn at ->
      at |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    end

    body =
      Enum.join(
        [
          "BEGIN:VCALENDAR",
          "VERSION:2.0",
          "PRODID:-//Burrow//Booking//EN",
          "BEGIN:VEVENT",
          "UID:#{receipt.id}@burrow",
          "DTSTAMP:#{stamp.(DateTime.utc_now())}",
          "DTSTART:#{stamp.(receipt.starts_at)}",
          "DTEND:#{stamp.(receipt.ends_at)}",
          "SUMMARY:#{ics_text("#{policy.title} with #{policy.owner_name}")}",
          "END:VEVENT",
          "END:VCALENDAR"
        ],
        "\r\n"
      )

    "data:text/calendar;charset=utf-8," <> URI.encode(body, &URI.char_unreserved?/1)
  end

  defp ics_text(text), do: String.replace(text, ~r/[\\;,]/, &("\\" <> &1))

  defp month_cells(month) do
    lead = Date.day_of_week(month) - 1
    List.duplicate(nil, lead) ++ Enum.to_list(Date.range(month, Date.end_of_month(month)))
  end

  def render(assigns) do
    ~H"""
    <main class="cal-guest-wrap bg-base-200 text-base-content" data-page="public-booking">
      <div :if={is_nil(@policy)} class="cal-guest-card cal-guest-card-empty">
        <p role="alert" class="m-0 p-6 text-[13px]">{@error}</p>
      </div>

      <div :if={@policy && @step == :done} class="cal-guest-card" data-step="done">
        <div class="cal-guest-done">
          <span class="cal-guest-tick"><.icon name="hero-check" class="size-7" /></span>
          <h1>You’re booked</h1>
          <p class="m-0 text-subtle">{@policy.title} with {@policy.owner_name}</p>
          <div class="cal-guest-box">
            <div><b>{long_day(DateTime.to_date(local(@receipt.starts_at, @zone)))}</b></div>
            <div>
              {hm(@receipt.starts_at, @zone)}–{hm(@receipt.ends_at, @zone)} · {@zone}
            </div>
            <div class="text-subtle">
              {@guest["name"]}{if @guest["email"] != "", do: " · " <> @guest["email"]}
            </div>
          </div>
          <%= cond do %>
            <% @policy.create_meeting and is_nil(@receipt.delivery_error) -> %>
              <div class="cal-guest-invite" role="status">
                <.icon name="hero-envelope" class="size-[18px] shrink-0" />
                <span>
                  <b>Guest invite sent to {@guest["email"]}</b>
                  <br />
                  <span class="text-subtle">
                    It has the Burrow meeting link. No account needed: open the link at {hm(
                      @receipt.starts_at,
                      @zone
                    )} and you’re in.
                  </span>
                </span>
              </div>
            <% @policy.create_meeting -> %>
              <p role="alert" class="m-0 max-w-[420px] text-error">
                Your booking is saved, but the guest email could not be delivered. Contact the organizer for your invitation.
              </p>
            <% true -> %>
              <p class="m-0 max-w-[420px] text-subtle">
                {first_name(@policy.owner_name)} has it on their calendar. Save this page or add it to your calendar.
              </p>
          <% end %>
          <div class="cal-segs justify-center">
            <a
              href={ics(@receipt, @policy)}
              download="booking.ics"
              class="cal-guest-ghost"
            >
              Add to my calendar
            </a>
            <button type="button" class="cal-guest-ghost" phx-click="again">Book another time</button>
          </div>
        </div>
      </div>

      <div :if={@policy && @step != :done} class="cal-guest-card" data-step={@step}>
        <div class="cal-guest-host">
          <span class="cal-guest-avatar">{initial(@policy.owner_name)}</span>
          <div class="cal-guest-who">
            {@policy.owner_name}{if @policy.org_name, do: " · " <> @policy.org_name}
          </div>
          <h1>{@policy.title}</h1>
          <div class="cal-guest-ln">
            <.icon name="hero-clock" class="size-[18px]" />{@policy.duration_minutes} minutes
          </div>
          <div :if={@policy.create_meeting} class="cal-guest-ln">
            <.icon name="hero-video-camera" class="size-[18px]" />Burrow meeting, link sent by email
          </div>
          <div :if={!@policy.create_meeting} class="cal-guest-ln">
            <.icon name="hero-calendar" class="size-[18px]" />Calendar invite only
          </div>
          <div class="cal-guest-ln">
            <.icon name="hero-globe-alt" class="size-[18px]" />{zone_label(@zone)}
          </div>
          <div :if={@day && @slot} class="cal-guest-ln font-semibold">
            <.icon name="hero-calendar" class="size-[18px]" />{long_day(@day)} · {hm(
              @slot.starts_at,
              @zone
            )}
          </div>
        </div>

        <%= if @step == :pick do %>
          <div class="cal-guest-picker">
            <h2>Pick a day</h2>
            <p :if={@error} role="alert" class="cal-err">{@error}</p>
            <div class="cal-guest-mh">
              <span class="flex-1">{Calendar.strftime(@month, "%B %Y")}</span>
              <button
                type="button"
                class={PlatformWeb.CalendarLive.Components.icon_btn()}
                phx-click="month"
                phx-value-direction="previous"
                aria-label="Previous month"
                disabled={Date.compare(@month, Date.beginning_of_month(@today)) != :gt}
              >
                <.icon name="hero-chevron-left" class="size-[18px]" />
              </button>
              <button
                type="button"
                class={PlatformWeb.CalendarLive.Components.icon_btn()}
                phx-click="month"
                phx-value-direction="next"
                aria-label="Next month"
              >
                <.icon name="hero-chevron-right" class="size-[18px]" />
              </button>
            </div>
            <div class="cal-guest-cal">
              <span :for={d <- ~w(Mo Tu We Th Fr Sa Su)} class="cal-guest-dw">{d}</span>
              <%= for cell <- month_cells(@month) do %>
                <span :if={is_nil(cell)}></span>
                <button
                  :if={cell}
                  type="button"
                  phx-click="pick"
                  phx-value-date={Date.to_iso8601(cell)}
                  class={[
                    (Map.get(@open, cell, 0) > 0 and Date.compare(cell, @today) != :lt) && "cal-open",
                    cell == @today && "cal-today-ring"
                  ]}
                  aria-pressed={to_string(cell == @day)}
                  disabled={Map.get(@open, cell, 0) == 0 or Date.compare(cell, @today) == :lt}
                  aria-label={
                    if Map.get(@open, cell, 0) > 0,
                      do: "#{long_day(cell)}, #{@open[cell]} times open",
                      else: "#{long_day(cell)}, unavailable"
                  }
                >
                  {cell.day}
                </button>
              <% end %>
            </div>
            <div class="cal-hint">
              Highlighted days have open times. Busy time on {first_name(@policy.owner_name)}’s calendars is already taken out.
            </div>
          </div>
          <div class="cal-guest-times">
            <h2>{if @day, do: long_day(@day), else: "Times"}</h2>
            <p :if={!@day} class="cal-hint m-0">Choose a day to see open times.</p>
            <div :if={@day} class="cal-guest-list">
              <button
                :for={slot <- @slots}
                type="button"
                class="cal-guest-slot"
                phx-click="slot"
                phx-value-start={DateTime.to_iso8601(slot.starts_at)}
                aria-pressed={to_string(@slot == slot)}
              >
                {hm(slot.starts_at, @zone)}
              </button>
            </div>
          </div>
        <% else %>
          <form
            id="public-booking-form"
            class="cal-guest-form"
            phx-submit="confirm"
            phx-change="keep"
            novalidate
          >
            <div class="cal-guest-chosen">
              <.icon name="hero-calendar" class="size-[18px] shrink-0 text-subtle" />
              <span class="flex-1">
                <b>{long_day(@day)}</b> · {hm(@slot.starts_at, @zone)}–{hm(@slot.ends_at, @zone)}
              </span>
              <button type="button" class="cal-guest-ghost" phx-click="change">Change</button>
            </div>
            <label class="cal-field">
              <span>Your name <span class="text-error" aria-hidden="true">*</span></span>
              <input
                id="g-n"
                name="guest[name]"
                value={@guest["name"]}
                autocomplete="name"
                maxlength="120"
                class="cal-input"
                aria-required="true"
                aria-invalid={to_string(Map.has_key?(@errors, :name))}
                aria-describedby="g-n-err"
              />
              <span id="g-n-err" class="cal-err">{@errors[:name]}</span>
            </label>
            <label class="cal-field">
              <span>
                Email
                <span :if={@policy.create_meeting} class="text-error" aria-hidden="true">*</span>
                <span :if={!@policy.create_meeting} class="cal-hint">(optional)</span>
              </span>
              <input
                id="g-e"
                name="guest[email]"
                type="email"
                value={@guest["email"]}
                autocomplete="email"
                maxlength="254"
                class="cal-input"
                aria-required={to_string(@policy.create_meeting)}
                aria-invalid={to_string(Map.has_key?(@errors, :email))}
                aria-describedby="g-e-err g-e-hint"
              />
              <span id="g-e-hint" class="cal-hint">
                {if @policy.create_meeting,
                  do: "Required: we email you the Burrow meeting link.",
                  else: "Only used to send you a confirmation."}
              </span>
              <span id="g-e-err" class="cal-err">{@errors[:email]}</span>
            </label>
            <label class="cal-field">
              <span>
                Anything {first_name(@policy.owner_name)} should know?
                <span class="cal-hint">(optional)</span>
              </span>
              <textarea id="g-notes" name="guest[notes]" maxlength="2000" class="cal-input">{@guest["notes"]}</textarea>
            </label>
            <div class="cal-segs">
              <button type="submit" class="cal-guest-confirm">Confirm booking</button>
              <button type="button" class="cal-guest-ghost !h-10" phx-click="change">Back</button>
            </div>
          </form>
        <% end %>
      </div>

      <div class="cal-guest-foot">
        <img src={~p"/images/burrow-mark.svg"} alt="" class="h-4" />Scheduling by Burrow
      </div>
    </main>
    """
  end
end
