defmodule PlatformWeb.AdminSignInUsersLive do
  @moduledoc """
  Admin · Users: manage the install's sign-in users (the bundled pocket-id)
  from Burrow (task 01a113ea-3ef4-7001-b3fc-5d0a1bafc5df, stage 3). The UI over
  `Platform.SignInAdmin`; design source is Saru's "Admin Users page" canvas.

  ## Gate, three places

    * `PlatformWeb.Plugs.RequireSignInAdmin` answers 404 on the HTTP request
      for every caller while `Platform.SignInAdmin.Config.enabled?/0` is
      false. It runs before `:require_auth`, so a signed-out caller gets the
      same 404 as an admin.
    * `mount/3` raises the same 404, which covers a websocket mount after the
      environment changed under a running node.
    * `/admin` renders the tile only while the switch is on.

  ## Admin check on mount AND on every event (layer 1 of 2)

  `:ensure_admin` refuses a non-admin mount. Every `handle_event/3` then runs
  `guard/1` first, which re-reads the gate and `Platform.Tenancy.root_admin?/1`
  from the database instead of trusting the mount-time `:root_admin?` assign,
  so an admin demoted while the page is open is refused on their next click
  with a flash and a navigation to `/`, before the context is called. The
  context re-checks both on every call (layer 2), so neither layer is
  load-bearing alone.

  ## The sign-in link is a credential

  A minted `Platform.SignInAdmin.Link` lives in the `:slip` assign only while
  the slip is open. Done, the close button, Escape and the backdrop all clear
  it; one timer at `expires_at` swaps in the expired copy. The row then shows
  "Link expires HH:MM" from `:link_expiries`, a map of user id to expiry that
  holds no link. Nothing here logs the link or the code.
  """

  use PlatformWeb, :live_view

  alias Platform.Accounts
  alias Platform.SignInAdmin
  alias Platform.SignInAdmin.{Config, Link}
  alias Platform.Tenancy
  alias PlatformWeb.MeetingLive.CalendarWindow
  alias PlatformWeb.Plugs.RequireSignInAdmin.NotFoundError

  @undo_ms 8_000
  @status_order %{pending: 0, disabled: 1}

  # ── Mount ───────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if not Config.enabled?(), do: raise(NotFoundError)

    zone =
      if connected?(socket),
        do: CalendarWindow.resolve_time_zone((get_connect_params(socket) || %{})["timezone"])

    socket =
      socket
      |> assign(:page_title, "Users")
      |> assign(:current_path, "/admin/sign-in-users")
      |> assign(:time_zone, zone)
      |> assign(:pocket_id_admin_url, pocket_id_admin_url())
      |> assign(:service, :loading)
      |> assign(:query, "")
      |> assign(:invite_open?, false)
      |> assign(:invite_values, blank_invite())
      |> assign(:invite_email_error, nil)
      |> assign(:invite_error, nil)
      |> assign(:slip, nil)
      |> assign(:link_expiries, %{})
      |> assign(:remove_target, nil)
      |> assign(:undo, nil)
      |> assign_suite_rows()
      |> load_identities()
      |> assign_visible()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  # ── Events: every one passes guard/1 first ─────────────────────────────

  @impl true
  def handle_event(event, params, socket) do
    case guard(socket) do
      :ok ->
        {:noreply, socket} = event(event, params, socket)
        {:noreply, assign_visible(socket)}

      {:denied, socket} ->
        {:noreply, socket}
    end
  end

  # The rows the table shows: search-filtered. Recomputed after every
  # callback that can change `:rows` or `:query`.
  defp assign_visible(socket),
    do: assign(socket, :visible, visible_rows(socket.assigns.rows, socket.assigns.query))

  @doc false
  # Fresh reads, never the mount-time `:root_admin?` assign.
  def guard(socket) do
    if Config.enabled?() and Tenancy.root_admin?(socket.assigns[:current_user_record]) do
      :ok
    else
      {:denied, deny(socket)}
    end
  end

  defp deny(socket) do
    socket
    |> put_flash(:error, "You don't have access to that page.")
    |> push_navigate(to: "/")
  end

  defp event("search", params, socket) do
    {:noreply, assign(socket, :query, Map.get(params, "q", ""))}
  end

  defp event("clear_search", _params, socket), do: {:noreply, assign(socket, :query, "")}

  defp event("retry", _params, socket) do
    {:noreply, socket |> assign(:service, :loading) |> load_identities()}
  end

  defp event("open_invite", _params, socket) do
    {:noreply,
     socket
     |> assign(:invite_open?, true)
     |> assign(:invite_values, blank_invite())
     |> assign(:invite_email_error, nil)
     |> assign(:invite_error, nil)}
  end

  defp event("close_invite", _params, socket),
    do: {:noreply, assign(socket, :invite_open?, false)}

  defp event("invite", %{"invite" => params}, socket) when is_map(params) do
    values = Map.merge(blank_invite(), Map.take(params, ["email", "name", "role"]))
    actor = socket.assigns.current_user_record

    attrs = %{email: values["email"], name: values["name"], role: values["role"]}

    case SignInAdmin.invite(actor, attrs) do
      {:ok, %{user: user, link: link}} ->
        {:noreply,
         socket
         |> assign(:invite_open?, false)
         |> open_slip(user, link, :invite)
         |> assign_suite_rows()
         |> load_identities()}

      {:error, reason} when reason in [:not_found, :unauthorized] ->
        {:noreply, socket |> assign(:invite_open?, false) |> action_error(reason, nil)}

      {:error, :invalid_email} ->
        {:noreply,
         socket
         |> assign(:invite_values, values)
         |> assign(:invite_email_error, "Enter an email address.")
         |> assign(:invite_error, nil)}

      {:error, :already_exists} ->
        {:noreply,
         socket
         |> assign(:invite_values, values)
         |> assign(:invite_email_error, {:duplicate, existing_name(socket, values["email"])})
         |> assign(:invite_error, nil)}

      {:error, :link_failed} ->
        name = display_invite_name(values)

        {:noreply,
         socket
         |> assign(:invite_open?, false)
         |> put_flash(
           :error,
           "#{name} was invited, but the sign-in link couldn't be created. Use Send link."
         )
         |> assign_suite_rows()
         |> load_identities()}

      {:error, :identity_in_use} ->
        {:noreply,
         socket
         |> assign(:invite_values, values)
         |> assign(:invite_email_error, nil)
         |> assign(
           :invite_error,
           "That sign-in account is already linked to another Burrow user. Nothing was saved."
         )}

      {:error, _other} ->
        {:noreply,
         socket
         |> assign(:invite_values, values)
         |> assign(:invite_email_error, nil)
         |> assign(
           :invite_error,
           "Couldn't create the sign-in account. Nothing was saved. Try again."
         )}
    end
  end

  defp event("invite", _params, socket), do: {:noreply, socket}

  defp event("show_in_list", %{"email" => email}, socket) do
    {:noreply, socket |> assign(:invite_open?, false) |> assign(:query, email)}
  end

  defp event("close_slip", _params, socket), do: {:noreply, assign(socket, :slip, nil)}

  defp event("resend_link", %{"id" => id}, socket) do
    actor = socket.assigns.current_user_record

    case SignInAdmin.resend_link(actor, id) do
      {:ok, %Link{} = link} ->
        user = Accounts.get_user(id)
        {:noreply, open_slip(socket, user, link, :resend)}

      {:error, reason} ->
        {:noreply, action_error(socket, reason, id)}
    end
  end

  defp event("disable", %{"id" => id}, socket) do
    actor = socket.assigns.current_user_record

    case SignInAdmin.disable(actor, id) do
      {:ok, user} ->
        ref = make_ref()
        Process.send_after(self(), {:clear_undo, ref}, @undo_ms)

        {:noreply,
         socket
         |> assign(:undo, %{ref: ref, user_id: user.id, name: user.name})
         |> mark_status(user.id, :disabled)
         |> load_identities()}

      {:error, reason} ->
        {:noreply, action_error(socket, reason, id)}
    end
  end

  defp event(name, %{"id" => id}, socket) when name in ["enable", "undo_disable"] do
    actor = socket.assigns.current_user_record

    # Only Undo may skip the live-link check, and the context bounds it to
    # 30 seconds after the Disable (task 01a114c1).
    case SignInAdmin.enable(actor, id, undo: name == "undo_disable") do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:undo, nil)
         |> put_flash(:info, "#{user.name} can sign in again.")
         |> assign_suite_rows()
         |> load_identities()}

      {:error, reason} ->
        {:noreply, action_error(socket, reason, id)}
    end
  end

  defp event("dismiss_undo", _params, socket), do: {:noreply, assign(socket, :undo, nil)}

  defp event("open_remove", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.rows, &(&1.id == id)) do
      nil -> {:noreply, socket}
      row -> {:noreply, assign(socket, :remove_target, %{id: row.id, name: row.name})}
    end
  end

  defp event("close_remove", _params, socket), do: {:noreply, assign(socket, :remove_target, nil)}

  defp event("remove", %{"id" => id}, socket) do
    actor = socket.assigns.current_user_record

    case SignInAdmin.remove(actor, id) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:remove_target, nil)
         |> put_flash(:info, "Removed #{user.name}.")
         |> assign_suite_rows()
         |> load_identities()}

      {:error, reason} ->
        {:noreply, socket |> assign(:remove_target, nil) |> action_error(reason, id)}
    end
  end

  defp event(_event, _params, socket), do: {:noreply, socket}

  # ── Async + timers ──────────────────────────────────────────────────────

  @impl true
  def handle_async(:identities, {:ok, {:ok, context_rows}}, socket) do
    {:noreply,
     socket
     |> assign(:service, :ok)
     |> assign(:rows, context_rows |> Enum.map(&row_from_context(&1, socket)) |> sort_rows())
     |> assign_visible()}
  end

  def handle_async(:identities, {:ok, {:error, reason}}, socket)
      when reason in [:not_found, :unauthorized] do
    {:noreply, deny(socket)}
  end

  def handle_async(:identities, _failed, socket) do
    {:noreply,
     socket |> assign(:service, :unreachable) |> assign_suite_rows() |> assign_visible()}
  end

  @impl true
  def handle_info({:slip_expired, ref}, %{assigns: %{slip: %{ref: ref} = slip}} = socket) do
    {:noreply, assign(socket, :slip, %{slip | link: nil})}
  end

  def handle_info({:clear_undo, ref}, %{assigns: %{undo: %{ref: ref}}} = socket) do
    {:noreply, assign(socket, :undo, nil)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Assign helpers ──────────────────────────────────────────────────────

  defp load_identities(socket) do
    if connected?(socket) do
      actor = socket.assigns.current_user_record
      start_async(socket, :identities, fn -> SignInAdmin.list_users(actor) end)
    else
      socket
    end
  end

  # Burrow rows render at once; pocket-id statuses arrive with the async load.
  defp assign_suite_rows(socket) do
    users = Accounts.list_users(include_archived: true)
    admins = MapSet.new(for u <- users, Tenancy.root_admin?(u), do: u.id)
    status = if socket.assigns.service == :unreachable, do: :unknown, else: :loading

    rows =
      users
      |> Enum.map(&suite_row(&1, status, admins, socket))
      |> sort_rows()

    socket
    |> assign(:admin_ids, admins)
    |> assign(:rows, rows)
  end

  defp suite_row(user, status, admins, socket) do
    %{
      id: user.id,
      dom_id: "user-#{user.id}",
      name: user.name || user.email,
      email: user.email,
      avatar_url: user.avatar_url,
      role: if(MapSet.member?(admins, user.id), do: :admin, else: :member),
      status: status,
      archived?: not is_nil(user.archived_at),
      self?: self?(socket, user.id)
    }
  end

  defp row_from_context(%{user: nil, pocket_id: identity, status: status}, _socket) do
    %{
      id: nil,
      dom_id: "pocket-id-#{identity.id}",
      name: identity_name(identity),
      email: identity.email,
      avatar_url: nil,
      role: nil,
      status: status,
      archived?: false,
      self?: false
    }
  end

  defp row_from_context(%{user: user, status: status}, socket) do
    suite_row(user, status, socket.assigns.admin_ids, socket)
  end

  defp identity_name(identity) do
    Enum.find(
      [Map.get(identity, :display_name), Map.get(identity, :email)],
      &(is_binary(&1) and &1 != "")
    )
  end

  defp mark_status(socket, user_id, status) do
    rows =
      Enum.map(socket.assigns.rows, fn
        %{id: ^user_id} = row -> %{row | status: status}
        row -> row
      end)

    assign(socket, :rows, sort_rows(rows))
  end

  defp sort_rows(rows) do
    Enum.sort_by(rows, fn row ->
      {Map.get(@status_order, row.status, 2), String.downcase(row.name || "")}
    end)
  end

  defp self?(socket, user_id) do
    case socket.assigns[:current_user_record] do
      %{id: ^user_id} -> true
      _ -> false
    end
  end

  defp open_slip(socket, user, %Link{} = link, origin) do
    ref = make_ref()
    ms = max(DateTime.diff(link.expires_at, DateTime.utc_now(), :millisecond), 0)
    Process.send_after(self(), {:slip_expired, ref}, ms)

    socket
    |> assign(:slip, %{
      ref: ref,
      origin: origin,
      user_id: user && user.id,
      name: (user && (user.name || user.email)) || "this user",
      link: link,
      expires_at: link.expires_at
    })
    |> assign(
      :link_expiries,
      Map.put(socket.assigns.link_expiries, user && user.id, link.expires_at)
    )
  end

  # The context's own refusals (layer 2). Deliberately NOT `deny/1`'s flash
  # and navigation: those come only from `guard/1`, so a test that sees them
  # proves layer 1 fired rather than the context behind it.
  defp action_error(socket, :unauthorized, _id),
    do: put_flash(socket, :error, "You don't have permission to do that.")

  defp action_error(socket, :not_found, _id),
    do: put_flash(socket, :error, "This page is switched off on this install.")

  defp action_error(socket, reason, id) do
    name = row_name(socket, id)

    message =
      case reason do
        :self -> "You can't disable or remove yourself"
        :no_identity -> "#{name} has no sign-in account."
        :disabled -> "#{name} is disabled. Enable them first."
        :archived -> "#{name} is archived. Enable them first."
        :user_not_found -> "User not found."
        {:sign_in_link_live, until} -> link_live_message(name, until)
        _ -> "Can't reach the sign-in service. Try again."
      end

    put_flash(socket, :error, message)
  end

  # Task 01a114c1: Enable waits until every link Burrow minted has expired.
  defp link_live_message(name, until) do
    "A sign-in link sent before #{name} was disabled is valid until #{Calendar.strftime(until, "%H:%M")} UTC. Enable them after that."
  end

  defp row_name(socket, id) do
    case Enum.find(socket.assigns.rows, &(&1.id == id)) do
      %{name: name} -> name
      nil -> "This user"
    end
  end

  defp existing_name(socket, email) do
    target = email |> to_string() |> String.trim() |> String.downcase()

    case Enum.find(
           socket.assigns.rows,
           &(is_binary(&1.email) and String.downcase(&1.email) == target)
         ) do
      %{name: name} -> name
      nil -> target
    end
  end

  defp display_invite_name(%{"name" => name, "email" => email}) do
    case String.trim(name || "") do
      "" -> String.trim(email || "")
      trimmed -> trimmed
    end
  end

  defp blank_invite, do: %{"email" => "", "name" => "", "role" => "member"}

  defp pocket_id_admin_url do
    Config.public_base() <> "/settings/admin"
  rescue
    _ -> nil
  end

  # ── Template helpers ────────────────────────────────────────────────────

  @doc false
  def visible_rows(rows, query) do
    case query |> to_string() |> String.trim() |> String.downcase() do
      "" ->
        rows

      q ->
        Enum.filter(rows, fn row ->
          String.contains?(String.downcase(row.name || ""), q) or
            String.contains?(String.downcase(row.email || ""), q)
        end)
    end
  end

  @doc false
  def initials(name) do
    name
    |> to_string()
    |> String.split(~r/[\s@._-]+/u, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
    |> case do
      "" -> "?"
      letters -> letters
    end
  end

  @doc false
  def role_label(:admin), do: "Admin"
  def role_label(:member), do: "Member"
  def role_label(_), do: nil

  @doc false
  def clock(%DateTime{} = dt, zone) do
    case zone && DateTime.shift_zone(dt, zone) do
      {:ok, local} -> Calendar.strftime(local, "%H:%M")
      _ -> Calendar.strftime(dt, "%H:%M") <> " UTC"
    end
  end

  @doc false
  def expiry_line(expiries, row, zone) do
    case Map.get(expiries, row.id) do
      %DateTime{} = at when row.status in [:pending, :active, :loading] ->
        if DateTime.compare(at, DateTime.utc_now()) == :gt,
          do: "Link expires #{clock(at, zone)}",
          else: "Link expired"

      _ ->
        nil
    end
  end

  attr :expiries, :map, required: true
  attr :row, :map, required: true
  attr :time_zone, :string, default: nil
  attr :class, :string, default: nil

  def expiry_note(assigns) do
    assigns =
      assign(assigns, :line, expiry_line(assigns.expiries, assigns.row, assigns.time_zone))

    ~H"""
    <div :if={@line} class={["text-xs text-base-content/70", @class]} data-role="link-expiry">
      {@line}
    </div>
    """
  end

  @doc "The 12-character code in groups of four, for reading aloud."
  def group_code(code) when is_binary(code) do
    code
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join(" ", &Enum.join/1)
  end

  @doc false
  def actionable?(service), do: service == :ok

  attr :row, :map, required: true

  def status_pill(assigns) do
    ~H"""
    <%= case @row.status do %>
      <% :loading -> %>
        <span class="skeleton inline-block h-4 w-16" data-role="status-loading">
          <span class="sr-only">Loading</span>
        </span>
      <% :unknown -> %>
        <span class="text-xs text-base-content/70" data-role="status-unknown">N/A</span>
      <% :pending -> %>
        <span class="badge badge-info badge-sm gap-1" data-role="status-pending">
          <span class="hero-clock size-3.5" aria-hidden="true"></span> Pending
        </span>
      <% :disabled -> %>
        <span class="badge badge-ghost badge-outline badge-sm gap-1" data-role="status-disabled">
          <span class="hero-no-symbol size-3.5" aria-hidden="true"></span> Disabled
        </span>
      <% :active -> %>
        <span class="sr-only" data-role="status-active">Active</span>
      <% :no_identity -> %>
        <span class="badge badge-ghost badge-sm" data-role="status-no-identity">
          {if @row.archived?, do: "Removed", else: "No sign-in account"}
        </span>
      <% :not_in_suite -> %>
        <span class="badge badge-ghost badge-sm" data-role="status-not-in-suite">
          Not in Burrow
        </span>
    <% end %>
    """
  end

  attr :row, :map, required: true
  attr :mobile, :boolean, default: false

  def row_actions(assigns) do
    assigns =
      assign(assigns, :btn, [
        "btn btn-sm btn-ghost",
        assigns.mobile && "min-h-11"
      ])

    ~H"""
    <div class={["flex items-center gap-1", !@mobile && "justify-end", @mobile && "flex-wrap"]}>
      <button
        :if={@row.id && @row.status in [:pending, :active] && !@row.archived?}
        type="button"
        class={@btn}
        phx-click="resend_link"
        phx-value-id={@row.id}
        data-role="resend-link"
      >
        Send link
      </button>
      <button
        :if={@row.id && @row.status == :disabled}
        type="button"
        class={@btn}
        phx-click="enable"
        phx-value-id={@row.id}
        data-role="enable"
      >
        Enable
      </button>
      <%= if @row.self? do %>
        <button
          type="button"
          class={@btn}
          disabled
          title="You can't disable or remove yourself"
          data-role="disable"
          data-disabled-reason="self"
        >
          Disable
        </button>
        <button
          type="button"
          class={@btn}
          disabled
          title="You can't disable or remove yourself"
          data-role="open-remove"
          data-disabled-reason="self"
        >
          Remove
        </button>
      <% else %>
        <button
          :if={@row.id && @row.status in [:pending, :active]}
          type="button"
          class={@btn}
          phx-click="disable"
          phx-value-id={@row.id}
          data-role="disable"
        >
          Disable
        </button>
        <button
          :if={@row.id && !(@row.status == :no_identity && @row.archived?)}
          type="button"
          class={@btn}
          phx-click="open_remove"
          phx-value-id={@row.id}
          data-role="open-remove"
        >
          Remove
        </button>
      <% end %>
    </div>
    """
  end
end
