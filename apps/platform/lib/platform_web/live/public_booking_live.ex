defmodule PlatformWeb.PublicBookingLive do
  use Phoenix.LiveView, log: false
  import PlatformWeb.CoreComponents
  alias Platform.Calendar.{BookingLinks, BookingRateLimit}

  def mount(%{"token" => token}, _, socket) do
    peer = get_connect_info(socket, :peer_data)
    ip = if peer, do: peer.address, else: :http

    policy =
      case BookingLinks.public_policy(token) do
        {:ok, policy} -> policy
        _ -> %{time_zone: "Etc/UTC", requires_email: false}
      end

    {:ok,
     assign(socket,
       page_title: "Book a time",
       token: token,
       ip: ip,
       zone: policy.time_zone,
       requires_email: policy.requires_email,
       date: DateTime.utc_now() |> DateTime.shift_zone!(policy.time_zone) |> DateTime.to_date(),
       slots: [],
       selected: nil,
       error: nil,
       receipt: nil,
       key: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
       form: to_form(%{}, as: :guest)
     )
     |> load_slots()}
  end

  def handle_event("date", %{"date" => date}, socket) do
    case Date.from_iso8601(date) do
      {:ok, date} -> {:noreply, socket |> assign(date: date, selected: nil) |> load_slots()}
      _ -> {:noreply, assign(socket, error: "Choose a valid date.")}
    end
  end

  def handle_event("select", %{"start" => start}, socket) do
    slot = Enum.find(socket.assigns.slots, &(DateTime.to_iso8601(&1.starts_at) == start))
    {:noreply, assign(socket, selected: slot, error: nil)}
  end

  def handle_event("book", %{"guest" => guest}, socket) do
    attrs = Map.take(guest, ["name", "email"])

    result =
      with %{starts_at: start} <- socket.assigns.selected,
           :ok <- check_rate(socket),
           do:
             BookingLinks.book(
               socket.assigns.token,
               Map.put(attrs, "starts_at", DateTime.to_iso8601(start)),
               socket.assigns.key
             )

    case result do
      {:ok, receipt} ->
        {:noreply, assign(socket, receipt: receipt, slots: [], selected: nil, error: nil)}

      _ ->
        {:noreply,
         socket
         |> load_slots()
         |> assign(
           error:
             "This time could not be booked. Check your details and choose an available time. Meeting bookings require an email address."
         )}
    end
  end

  defp check_rate(socket) do
    if connected?(socket), do: BookingRateLimit.check({:ip, socket.assigns.ip}, 1, 60), else: :ok
  end

  defp load_slots(socket) do
    result =
      with :ok <- check_rate(socket),
           {:ok, policy} <- BookingLinks.public_policy(socket.assigns.token),
           {:ok, slots} <- BookingLinks.slots(socket.assigns.token, socket.assigns.date),
           do: {:ok, policy, slots}

    case result do
      {:ok, policy, slots} ->
        assign(socket,
          slots: slots,
          error: nil,
          zone: policy.time_zone,
          requires_email: policy.requires_email
        )

      _ ->
        assign(socket,
          slots: [],
          selected: nil,
          error:
            "Availability cannot be confirmed right now. Try again later or contact the organizer."
        )
    end
  end

  defp local_time(datetime, zone, format),
    do: datetime |> DateTime.shift_zone!(zone) |> Calendar.strftime(format)

  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 text-base-content">
      <div class="mx-auto max-w-xl space-y-5 rounded-2xl border border-edge bg-base-100 p-5 sm:p-8">
        <h1 class="text-2xl font-semibold">Book a time</h1>
        <p class="text-sm text-subtle">
          Choose an available time. All dates and times are in {@zone}.
        </p>
        <p :if={@error} role="alert" class="rounded-lg bg-error/10 p-3 text-error">{@error}</p>
        <section :if={@receipt} aria-label="Booking confirmation" class="space-y-3">
          <h2 class="text-xl font-semibold">You're booked</h2>
          <p>{local_time(@receipt.starts_at, @zone, "%b %d, %Y at %H:%M")}</p>
          <p :if={@receipt.delivery_error} role="alert" class="text-error">
            Your booking is saved, but the guest email could not be delivered. Contact the organizer for your invitation.
          </p>
        </section>
        <div :if={!@receipt} class="space-y-5">
          <form id="booking-date-form" phx-change="date">
            <label for="booking-date" class="block text-sm font-medium">Date in {@zone}</label>
            <input
              id="booking-date"
              name="date"
              type="date"
              value={@date}
              class="input input-bordered mt-2 w-full"
              required
            />
          </form>
          <p :if={@slots == [] && !@error} class="text-subtle">No available times on this date.</p>
          <div class="grid grid-cols-2 gap-2 sm:grid-cols-3" aria-label="Available times">
            <button
              :for={slot <- @slots}
              phx-click="select"
              phx-value-start={DateTime.to_iso8601(slot.starts_at)}
              class={[
                "btn min-h-11",
                @selected == slot && "btn-primary",
                @selected != slot && "btn-outline"
              ]}
              aria-pressed={@selected == slot}
            >
              {local_time(slot.starts_at, @zone, "%H:%M")}
            </button>
          </div>
          <.form
            :if={@selected}
            for={@form}
            id="public-booking-form"
            phx-submit="book"
            class="space-y-4 border-t border-edge pt-4"
          >
            <h2 class="font-semibold">
              {local_time(@selected.starts_at, @zone, "%b %d at %H:%M")}
            </h2>
            <.input field={@form[:name]} label="Your name" required maxlength="120" />
            <.input
              field={@form[:email]}
              label={
                if @requires_email,
                  do: "Email (required for meeting invitation)",
                  else: "Email (optional)"
              }
              required={@requires_email}
              type="email"
              maxlength="254"
            />
            <button class="btn btn-primary min-h-11 w-full" phx-disable-with="Booking…">
              Confirm booking
            </button>
          </.form>
        </div>
      </div>
    </main>
    """
  end
end
