defmodule PlatformWeb.BookingSettingsLive do
  use PlatformWeb, :live_view
  alias Platform.Calendar.BookingLinks

  def mount(_, _, socket) do
    projects =
      Platform.Tasks.list_projects_for_user(socket.assigns.current_user_record)
      |> Enum.filter(&is_nil(&1.archived_at))

    {:ok,
     socket
     |> assign(
       page_title: "Booking links",
       editing: nil,
       error: nil,
       projects: projects,
       meetings:
         Platform.Meetings.Config.enabled?() and
           Platform.Access.can?(socket.assigns.access_scope, "meetings.join")
     )
     |> reset_form()
     |> reload()}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.links, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      link ->
        attrs =
          Map.from_struct(link)
          |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
          |> Map.put(
            "windows_text",
            Enum.map_join(link.windows, "\n", &"#{&1["weekday"]} #{&1["start"]}-#{&1["end"]}")
          )

        {:noreply, assign(socket, editing: id, form: to_form(attrs, as: :link), error: nil)}
    end
  end

  def handle_event("cancel", _, socket), do: {:noreply, reset_form(socket)}

  def handle_event("revoke", %{"id" => id}, socket) do
    case BookingLinks.revoke(socket.assigns.access_scope, id) do
      {:ok, _} -> {:noreply, reload(socket)}
      _ -> {:noreply, assign(socket, error: "Could not revoke this link.")}
    end
  end

  def handle_event("save", %{"link" => attrs}, socket) do
    windows =
      attrs
      |> Map.get("windows_text", "")
      |> String.split("\n", trim: true)
      |> Enum.map(fn row ->
        case Regex.run(~r/^([1-7])\s+(\d{2}:\d{2})-(\d{2}:\d{2})$/, String.trim(row)) do
          [_, day, first, last] ->
            %{"weekday" => String.to_integer(day), "start" => first, "end" => last}

          _ ->
            %{}
        end
      end)

    attrs = Map.put(attrs, "windows", windows)

    result =
      if socket.assigns.editing,
        do: BookingLinks.update(socket.assigns.access_scope, socket.assigns.editing, attrs),
        else: BookingLinks.create(socket.assigns.access_scope, attrs)

    case result do
      {:ok, _} ->
        {:noreply, socket |> reset_form() |> reload() |> put_flash(:info, "Booking link saved.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         assign(socket,
           form: to_form(Map.put(attrs, "windows_text", attrs["windows_text"]), as: :link),
           error:
             Enum.map_join(cs.errors, "; ", fn {field, {message, _}} -> "#{field}: #{message}" end)
         )}

      _ ->
        {:noreply,
         assign(socket,
           error:
             "Could not save this booking policy. Check your permissions and Meetings settings."
         )}
    end
  end

  defp reset_form(socket) do
    today = Date.utc_today()

    assign(socket,
      editing: nil,
      error: nil,
      form:
        to_form(
          %{
            "title" => "Meet with me",
            "time_zone" => "Etc/UTC",
            "duration_minutes" => 30,
            "buffer_before_minutes" => 0,
            "buffer_after_minutes" => 0,
            "start_date" => today,
            "end_date" => Date.add(today, 30),
            "windows_text" =>
              "1 09:00-17:00\n2 09:00-17:00\n3 09:00-17:00\n4 09:00-17:00\n5 09:00-17:00",
            "create_meeting" => false
          },
          as: :link
        )
    )
  end

  defp reload(socket) do
    receipts = BookingLinks.receipts(socket.assigns.access_scope)

    slugs =
      for receipt <- receipts,
          receipt.meeting_id,
          {:ok, meeting} <- [
            Platform.Meetings.get_meeting_for_user(
              socket.assigns.current_user_record,
              receipt.meeting_id
            )
          ],
          into: %{},
          do: {receipt.meeting_id, meeting.slug}

    assign(socket,
      links: BookingLinks.list(socket.assigns.access_scope),
      receipts: receipts,
      meeting_slugs: slugs
    )
  end

  def render(assigns) do
    ~H"""
    <main class="clears-tab-bar h-full overflow-auto bg-base-100 p-4 text-base-content lg:p-6">
      <div class="mx-auto max-w-3xl space-y-6">
        <.link navigate={~p"/calendar"} class="btn btn-ghost btn-sm">← Calendar</.link>
        <h1 class="text-2xl font-semibold">Booking links</h1>
        <p class="text-sm text-subtle">
          Share available times without revealing your calendar. All times follow the timezone you choose.
        </p>
        <p :if={@error} role="alert" class="rounded-lg bg-error/10 p-3 text-error">{@error}</p>
        <.form
          for={@form}
          id="booking-link-form"
          phx-submit="save"
          class="space-y-4 rounded-xl border border-edge p-4"
        >
          <h2 class="font-semibold">
            {if @editing, do: "Edit booking link", else: "New booking link"}
          </h2>
          <.input field={@form[:title]} label="Title" required />
          <.input
            field={@form[:time_zone]}
            label="Owner timezone"
            required
          />
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
            <.input
              field={@form[:duration_minutes]}
              type="number"
              label="Duration (minutes)"
              min="5"
              max="480"
              required
            />
            <.input
              field={@form[:buffer_before_minutes]}
              type="number"
              label="Buffer before"
              min="0"
              max="240"
            />
            <.input
              field={@form[:buffer_after_minutes]}
              type="number"
              label="Buffer after"
              min="0"
              max="240"
            />
          </div>
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <.input field={@form[:start_date]} type="date" label="First date" required />
            <.input field={@form[:end_date]} type="date" label="Last date" required />
          </div>
          <.input field={@form[:windows_text]} type="textarea" label="Weekly availability" required />
          <p class="text-xs text-subtle">
            One window per line: weekday start-end. Monday = 1, Sunday = 7. Example: 1 09:00-17:00
          </p>
          <div :if={@meetings} class="space-y-3">
            <.input
              field={@form[:create_meeting]}
              type="checkbox"
              label="Create a meeting with a guest invitation"
            />
            <p class="text-xs text-subtle">
              Confirmation email depends on the organizer’s configured mail sender. Failed delivery appears in booking receipts.
            </p>
            <.input
              field={@form[:project_id]}
              type="select"
              label="Meeting project"
              options={Enum.map(@projects, &{&1.name, &1.id})}
              prompt="Choose a project"
            />
          </div>
          <button class="btn btn-primary min-h-11">Save booking link</button>
          <button :if={@editing} type="button" phx-click="cancel" class="btn btn-ghost min-h-11">
            Cancel
          </button>
        </.form>
        <section class="space-y-3" aria-label="Your booking links">
          <h2 class="font-semibold">Your links</h2>
          <p :if={@links == []} class="text-sm text-subtle">No booking links yet.</p>
          <article :for={link <- @links} class="space-y-2 rounded-xl border border-edge p-4">
            <h3 class="font-semibold">{link.title}</h3>
            <p class="text-sm text-subtle">{link.duration_minutes} minutes · {link.time_zone}</p>
            <p :if={link.revoked_at}>Revoked</p>
            <.link
              :if={!link.revoked_at}
              href={~p"/book/#{link.token}"}
              class="block break-all text-sm underline"
            >
              {PlatformWeb.Endpoint.url() <> "/book/" <> link.token}
            </.link>
            <button
              :if={!link.revoked_at}
              phx-click="edit"
              phx-value-id={link.id}
              class="btn btn-ghost btn-sm min-h-11"
            >
              Edit
            </button>
            <button
              :if={!link.revoked_at}
              phx-click="revoke"
              phx-value-id={link.id}
              data-confirm="Revoke this booking link?"
              class="btn btn-ghost btn-sm min-h-11 text-error"
            >
              Revoke
            </button>
          </article>
        </section>
        <section class="space-y-3" aria-label="Booking receipts">
          <h2 class="font-semibold">Recent bookings</h2>
          <p :if={@receipts == []} class="text-sm text-subtle">No bookings yet.</p>
          <article :for={receipt <- @receipts} class="rounded-xl border border-edge p-4">
            <p>{receipt.name} · {Calendar.strftime(receipt.starts_at, "%b %d, %Y %H:%M UTC")}</p>
            <.link
              :if={@meeting_slugs[receipt.meeting_id]}
              navigate={~p"/meetings/#{@meeting_slugs[receipt.meeting_id]}"}
              class="btn btn-ghost btn-sm min-h-11"
            >
              Open meeting
            </.link>
            <p :if={receipt.delivery_error} role="alert" class="text-error">
              Guest email delivery failed. Contact the guest to confirm their booking.
            </p>
          </article>
        </section>
      </div>
    </main>
    """
  end
end
