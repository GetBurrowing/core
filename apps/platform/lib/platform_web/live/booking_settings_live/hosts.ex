defmodule PlatformWeb.BookingSettingsLive.Hosts do
  @moduledoc """
  The co-host parts of `/calendar/booking` (task 01a1eff0-6880 stage 3, design
  canvas `01a1eff0-b44c` node `d`, "SETTINGS > Hosts"):

    * `hosts_section/1`: the `Hosts` block inside the owner's link editor
      (owner row, co-host rows with their `Pending` / `Declined` / `Left`
      badge, `+ Add co-host` and its org-only member picker, and the
      `warning` strip shown only while the link offers no times);
    * `invite_card/1`: the invitee's accept/decline card, reached from the
      Inbox row's `/calendar/booking?cohost=<host_id>` url;
    * `cohosted/1`: `Links you co-host`, where a co-host accepts, declines or
      later leaves (declared deviation D3).

  Every write goes through `Platform.Calendar.BookingHosts`, which writes host
  rows only: nothing here touches an external calendar or sends mail. Host-set
  changes reach both the owner's and the co-host's open page through
  `BookingHosts.topic/1`.

  The editor autosaves, so host changes apply immediately and no Save button
  is added (declared deviation D1).
  """
  use PlatformWeb, :html

  import PlatformWeb.AvatarComponents, only: [human_avatar: 1]
  import PlatformWeb.CalendarLive.Components, only: [ghost_btn: 0, primary_btn: 0]

  alias Platform.Calendar.{BookingHosts, BookingLink, BookingLinkHost}
  alias Platform.Repo

  # ── state ───────────────────────────────────────────────────────────────

  @doc "Initial assigns, set once in `mount/3`."
  def init(socket) do
    if Phoenix.LiveView.connected?(socket),
      do: BookingHosts.subscribe(socket.assigns.current_user_record.id)

    socket
    |> Phoenix.Component.assign(host_picker: nil, cohost_invite: nil)
    |> load()
  end

  @doc """
  Reload the selected link's host rows and the viewer's co-hosted links.
  Call after the selection changes or a host-set change arrives.
  """
  def load(socket) do
    hosts =
      case selected(socket) do
        %BookingLink{} = link -> BookingHosts.list_for_link(link)
        _ -> []
      end

    blocked =
      case selected(socket) do
        %BookingLink{} = link when hosts != [] ->
          match?({:error, _}, BookingHosts.hosts_ready(link))

        _ ->
          false
      end

    invite =
      case socket.assigns[:cohost_invite] do
        %BookingLinkHost{id: id} -> pending_invite(socket, id)
        _ -> nil
      end

    Phoenix.Component.assign(socket,
      hosts: hosts,
      hosts_blocked: blocked,
      cohosted: BookingHosts.list_for_user(socket.assigns.current_user_record.id),
      cohost_invite: invite
    )
  end

  @doc "Open the invite card for `?cohost=<host_id>` when it is the viewer's pending invite."
  def open_invite(socket, nil), do: Phoenix.Component.assign(socket, :cohost_invite, nil)

  def open_invite(socket, host_id),
    do: Phoenix.Component.assign(socket, :cohost_invite, pending_invite(socket, host_id))

  defp pending_invite(socket, host_id) do
    user_id = socket.assigns.current_user_record.id

    with true <- is_binary(host_id) and Platform.UUID.valid?(host_id),
         %BookingLinkHost{status: "pending"} = host <-
           Repo.get_by(BookingLinkHost, id: host_id, user_id: user_id),
         %BookingLinkHost{link: %BookingLink{revoked_at: nil}} = host <-
           Repo.preload(host, link: :owner) do
      host
    else
      _ -> nil
    end
  end

  defp selected(socket),
    do: Enum.find(socket.assigns.links, &(&1.id == socket.assigns.selected))

  # ── events (every name starts with "host_") ─────────────────────────────

  @doc "Handle a `host_*` event from the Hosts section, the invite card or `Links you co-host`."
  def handle_event("host_picker_open", _, socket),
    do: {:noreply, Phoenix.Component.assign(socket, :host_picker, picker(socket, ""))}

  def handle_event("host_picker_close", _, socket),
    do: {:noreply, Phoenix.Component.assign(socket, :host_picker, nil)}

  def handle_event("host_search", %{"q" => query}, socket),
    do: {:noreply, Phoenix.Component.assign(socket, :host_picker, picker(socket, query))}

  def handle_event("host_add", %{"user" => user_id}, socket) do
    owner_action(socket, &BookingHosts.invite(&1, &2, user_id), "Co-host invited", fn s ->
      Phoenix.Component.assign(s, :host_picker, nil)
    end)
  end

  def handle_event("host_remove", %{"user" => user_id}, socket),
    do: owner_action(socket, &BookingHosts.remove(&1, &2, user_id), "Co-host removed")

  def handle_event("host_reinvite", %{"user" => user_id}, socket),
    do: owner_action(socket, &BookingHosts.reinvite(&1, &2, user_id), "Invite sent again")

  def handle_event("host_accept", %{"id" => id}, socket),
    do: cohost_action(socket, &BookingHosts.accept/2, id, "You’re co-hosting this link")

  def handle_event("host_decline", %{"id" => id}, socket),
    do: cohost_action(socket, &BookingHosts.decline/2, id, "Invite declined")

  def handle_event("host_leave", %{"id" => id}, socket),
    do: cohost_action(socket, &BookingHosts.leave/2, id, "You left this link")

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp picker(socket, query) do
    candidates =
      case selected(socket) do
        %BookingLink{id: id} ->
          BookingHosts.search_candidates(socket.assigns.access_scope, query, link_id: id)

        _ ->
          []
      end

    %{query: query, candidates: candidates}
  end

  defp owner_action(socket, fun, flash, after_ok \\ & &1) do
    with %BookingLink{id: id} <- selected(socket),
         {:ok, _} <- fun.(socket.assigns.access_scope, id) do
      {:noreply, socket |> after_ok.() |> load() |> Phoenix.LiveView.put_flash(:info, flash)}
    else
      error -> {:noreply, Phoenix.LiveView.put_flash(socket, :error, error_message(error))}
    end
  end

  defp cohost_action(socket, fun, id, flash) do
    case fun.(socket.assigns.access_scope, id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> Phoenix.Component.assign(:cohost_invite, nil)
         |> load()
         |> Phoenix.LiveView.put_flash(:info, flash)}

      error ->
        {:noreply, socket |> load() |> Phoenix.LiveView.put_flash(:error, error_message(error))}
    end
  end

  defp error_message({:error, :not_org_member}),
    do: "Only members of your organization can co-host."

  defp error_message({:error, :already_invited}), do: "They’re already a co-host of this link."
  defp error_message({:error, :revoked}), do: "This link has been revoked."
  defp error_message({:error, :forbidden}), do: "You can’t change co-hosts on this link."
  defp error_message({:error, :invalid_transition}), do: "That invite has already been answered."
  defp error_message(_), do: "Could not update the co-hosts of this link."

  # ── copy ────────────────────────────────────────────────────────────────

  @doc """
  The warning strip's line, or `nil` when the link is not blocked. Pending
  co-hosts: `Not offering times until Jordan accepts` (first names, joined
  `, ` then ` and `). Declined or left co-hosts (declared deviation D2):
  `Not offering times until you remove or re-invite Jordan`.
  """
  def blocked_line(_hosts, false), do: nil

  def blocked_line(hosts, true) do
    gone = for %{status: status} = h <- hosts, status in ["declined", "left"], do: first_name(h)
    pending = for %{status: "pending"} = h <- hosts, do: first_name(h)

    cond do
      gone != [] -> "Not offering times until you remove or re-invite #{join(gone)}"
      pending != [] -> "Not offering times until #{join(pending)} accepts" |> plural(pending)
      true -> "Not offering times until every co-host can share their free/busy times"
    end
  end

  defp plural(line, [_]), do: line
  defp plural(line, _), do: String.replace_suffix(line, " accepts", " accept")

  @doc "`Jordan`, `Jordan and Nathan`, `Jordan, Nathan and Sam`."
  def join([one]), do: one
  def join(names), do: Enum.join(Enum.drop(names, -1), ", ") <> " and " <> List.last(names)

  defp first_name(%BookingLinkHost{user: user}), do: first_name(user)

  defp first_name(%{name: name}) when is_binary(name),
    do: name |> String.split() |> List.first() || "Someone"

  defp first_name(_), do: "Someone"

  defp full_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp full_name(_), do: "Someone"

  defp badge("pending"), do: {"Pending", "badge-info"}
  defp badge("declined"), do: {"Declined", "badge-neutral"}
  defp badge("left"), do: {"Left", "badge-neutral"}
  defp badge(_), do: nil

  # ── components ──────────────────────────────────────────────────────────

  attr(:hosts, :list, required: true)
  attr(:blocked, :boolean, required: true)
  attr(:picker, :map, default: nil)

  @doc "The `Hosts` section of the owner's link editor."
  def hosts_section(assigns) do
    assigns = assign(assigns, :blocked_line, blocked_line(assigns.hosts, assigns.blocked))

    ~H"""
    <div class="cal-field" data-role="booking-hosts">
      <h3 class="text-sm font-semibold text-base-content">Hosts</h3>
      <div class="flex flex-col divide-y divide-base-300 rounded-box bg-base-100">
        <div class="flex items-center gap-3 px-3 py-2" data-role="booking-host-owner">
          <span class="min-w-0 flex-1 truncate text-base-content">You (owner)</span>
          <span class="shrink-0 text-xs text-base-content/70">Owner</span>
        </div>
        <div
          :for={host <- @hosts}
          class="flex flex-wrap items-center gap-x-3 gap-y-1 px-3 py-2"
          data-role="booking-host-row"
          data-status={host.status}
        >
          <.human_avatar
            name={full_name(host.user)}
            avatar_url={host.user && host.user.avatar_url}
            seed="booking-host"
            size="sm"
            class="shrink-0"
          />
          <span class="min-w-0 flex-1 truncate text-base-content">{full_name(host.user)}</span>
          <span
            :if={badge(host.status)}
            class={["badge badge-sm shrink-0", elem(badge(host.status), 1)]}
            data-role="booking-host-status"
          >
            {elem(badge(host.status), 0)}
          </span>
          <span class="flex shrink-0 items-center gap-1">
            <button
              :if={host.status in ["declined", "left"]}
              type="button"
              class={ghost_btn()}
              phx-click="host_reinvite"
              phx-value-user={host.user_id}
            >
              Invite again
            </button>
            <button
              type="button"
              class={ghost_btn()}
              phx-click="host_remove"
              phx-value-user={host.user_id}
              aria-label={"Remove #{full_name(host.user)}"}
            >
              Remove
            </button>
          </span>
        </div>
      </div>
      <button
        :if={is_nil(@picker)}
        type="button"
        class={[ghost_btn(), "self-start"]}
        phx-click="host_picker_open"
        data-role="booking-host-add"
      >
        + Add co-host
      </button>
      <div
        :if={@picker}
        class="flex flex-col gap-2 rounded-box bg-base-100 p-3"
        data-role="booking-host-picker"
      >
        <form phx-change="host_search" phx-submit="host_search" id="booking-host-search">
          <label for="booking-host-q" class="sr-only">Search members of your organization</label>
          <input
            id="booking-host-q"
            name="q"
            value={@picker.query}
            type="search"
            autocomplete="off"
            placeholder="Search members of your organization"
            class="cal-input w-full"
            phx-debounce="200"
          />
        </form>
        <ul class="flex flex-col">
          <li :for={user <- @picker.candidates}>
            <button
              type="button"
              class="flex w-full min-w-0 items-center gap-3 rounded-field px-2 py-1.5 text-left hover:bg-base-200"
              phx-click="host_add"
              phx-value-user={user.id}
              data-role="booking-host-candidate"
            >
              <.human_avatar
                name={full_name(user)}
                avatar_url={user.avatar_url}
                seed="booking-host"
                size="sm"
                class="shrink-0"
              />
              <span class="min-w-0 flex-1 truncate text-base-content">{full_name(user)}</span>
            </button>
          </li>
          <li :if={@picker.candidates == []} class="cal-hint px-2 py-1.5">
            No members of your organization match.
          </li>
        </ul>
        <button
          type="button"
          class={[ghost_btn(), "self-start"]}
          phx-click="host_picker_close"
        >
          Done
        </button>
      </div>
      <div
        :if={@blocked_line}
        role="status"
        class="flex items-start gap-2 rounded-box bg-warning px-3 py-2 text-sm text-warning-content"
        data-role="booking-hosts-blocked"
      >
        <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
        <span class="min-w-0">{@blocked_line}</span>
      </div>
    </div>
    """
  end

  attr(:invite, :any, required: true)

  @doc "The invitee's accept/decline card (canvas node d, \"Co-host invite\")."
  def invite_card(assigns) do
    ~H"""
    <section
      :if={@invite}
      class="cal-panel flex flex-col gap-3"
      data-role="booking-cohost-invite"
      aria-label="Co-host invite"
    >
      <h3>
        {first_name(@invite.link.owner)} invited you to co-host “{@invite.link.title}”
      </h3>
      <p class="!text-base-content">
        Your free/busy times will be used to offer slots on {first_name(@invite.link.owner)}'s link. Guests never see your calendar.
      </p>
      <div class="flex flex-wrap gap-2">
        <button type="button" class={primary_btn()} phx-click="host_accept" phx-value-id={@invite.id}>
          Accept
        </button>
        <button type="button" class={ghost_btn()} phx-click="host_decline" phx-value-id={@invite.id}>
          Decline
        </button>
      </div>
    </section>
    """
  end

  attr(:rows, :list, required: true)

  @doc "`Links you co-host` (declared deviation D3)."
  def cohosted(assigns) do
    ~H"""
    <section
      :if={@rows != []}
      class="cal-panel flex flex-col gap-2"
      data-role="booking-cohosted"
      aria-label="Links you co-host"
    >
      <h3>Links you co-host</h3>
      <div
        :for={host <- @rows}
        class="cal-setrow flex-wrap"
        data-role="booking-cohosted-row"
        data-status={host.status}
      >
        <span class="min-w-0 flex-1">
          <span class="block truncate">{host.link.title}</span>
          <small>{full_name(host.link.owner)}’s link</small>
        </span>
        <span :if={host.status == "pending"} class="badge badge-sm badge-info shrink-0">
          Pending
        </span>
        <span class="flex shrink-0 items-center gap-1">
          <%= if host.status == "pending" do %>
            <button type="button" class={ghost_btn()} phx-click="host_accept" phx-value-id={host.id}>
              Accept
            </button>
            <button
              type="button"
              class={ghost_btn()}
              phx-click="host_decline"
              phx-value-id={host.id}
            >
              Decline
            </button>
          <% else %>
            <button
              type="button"
              class={ghost_btn()}
              phx-click="host_leave"
              phx-value-id={host.id}
              data-confirm="Stop co-hosting this link? It stops offering times until the owner removes or re-invites you."
            >
              Leave
            </button>
          <% end %>
        </span>
      </div>
    </section>
    """
  end
end
