defmodule PlatformWeb.SocialLive do
  @moduledoc """
  The interim Social tab (task 01a140a9-9e19, Social 7/7), nested by core's
  generic `/m/<prefix>` page (`Platform.Extension.live_pages/0`).

  ## Nothing is inherited from the parent page

  Core hands this LiveView `%{"user_id" => id}` (plus the bounded, untrusted
  `"query"` described under the OAuth return) and runs no live_session
  hook on it. `mount/3` re-reads the user (`Platform.Accounts.get_user/1`),
  lists the profiles that user may see (`Platform.Social.list_profiles_for_user/1`,
  built on the RBAC swap points) and every event re-checks against a fresh
  read, never against an id the client sent.

  ## One profile at a time

  The header select is the profile switcher: the current profile's name at
  the page-title size, every option carrying its needs-approval count (ONE
  grouped query, `Platform.Social.needs_approval_counts/1`). Switching keeps
  the current tab and goes through ONE `load_profile/2`, which is where every
  per-profile stream is (re)loaded with `reset: true`, so nothing of the
  previous profile survives a switch.

  Tabs: Queue (n) | Calendar | Connections | Settings.

  ## Creating a profile (task 01a14668)

  A human creator ({:user, id}: `@user` non-nil) gets the create form as the
  empty state and a "+ New profile" entry next to the switcher. The target
  org is resolved server-side by `creatable_orgs/1` from a FRESH read of the
  user, never from a client org id; the only write is
  `Platform.Social.create_profile/2`, with the creator as first approver.
  Agent viewers (and anyone without a creatable org) get no control.

  ## The install's Zernio API key (task 01a14722)

  Settings carries ONE write-only row for the install-level Zernio key,
  shown to any live human (`%User{archived_at: nil}`) who reaches the pane,
  approver or not. It writes only through
  `Platform.Social.Secrets.put_zernio_api_key/2`, after `save_zernio_key`
  re-reads the user. The value is never rendered (not masked, not a prefix,
  not its fingerprint) and never kept in assigns: the form is rebuilt empty
  after every submit and has no phx-change, so the value reaches the server
  only on submit. Status is metadata only: Set or Not set, who and when.

  While the Zernio publisher is selected and no key is set, Connections
  shows a notice pointing at Settings and hides Connect/Reconnect.

  ## Adding an account (task 01a14801)

  Connections carries ONE "+ Add account" control, shown only to an approver
  of the profile (`@can_edit?`), only when Connect is not blocked on the
  Zernio key, and only when the publisher can connect something. Its picker
  offers exactly `Platform.Social.connectable_platforms/0` (the module only
  maps those values to display names). `add_account` re-checks through
  `authorize/1`, then `Platform.Social.add_account/4` (which ensures the
  vendor profile first and re-checks the approver itself), then the
  publisher's `connect_url/2`, then an external redirect. A connect failure
  AFTER the row exists re-streams the rows so it shows with Connect; the row
  is kept and retried, never deleted. `connect_account` also runs
  `Platform.Social.ensure_provider_profile/2` first, so Connect on a row that
  predates the vendor profile works. The vendor URL and the key are never
  logged.

  ## The OAuth return (task 01a14807)

  The vendor sends the browser back to `/m/social` with its result in the
  query string. This LiveView is nested, so it gets no `handle_params/3`;
  core forwards the query as a bounded map of UNTRUSTED strings in
  `session["query"]`, and `mount/3` reads it through ONE parser,
  `return_params/1`. Nothing happens on the static render (no vendor
  request), nor for a viewer who is not a live human (`human?/1`): no
  request, no notice.

    * Success (`profileId` + `accountId`, both shape-checked; anything else
      is malformed, with no request): the profile must be one of the
      viewer's VISIBLE profiles with that `provider_profile_ref`, else a
      "doesn't match" notice and no request. Then `authorize/1` and
      `Platform.Social.complete_connect/4` (approver re-checked inside), which
      asks the vendor's account list before writing. The URL's username and
      platform are never used for a write.
    * Failure (`error` present): a notice naming the code when it passes the
      shape check. No request, no write.

  The return landing does NOT also reconcile, so a return makes exactly one
  vendor list call.

  ## Picking up connections on opening Connections (task 01a14807)

  Accounts connected at the vendor before the return leg existed (or whose
  return never reached us) are picked up when the Connections pane opens:
  `select_tab` "connections", and `load_profile/2` while the tab already is
  (a profile switch reconciles the NEW profile). It runs only on a connected
  socket, for a viewer who passes `authorize/1`, on a profile with a
  `provider_profile_ref`, while at least one never-connected row is listed;
  `Platform.Social.reconcile_accounts/3` re-checks the approver and the ref
  and sends nothing when no row is pending. Picked-up rows show Connected
  with their handle and a "Picked up" notice; a vendor error shows a
  couldn't-check notice and writes nothing; no key sends nothing and adds no
  notice (the key alert already says it). RETRY: rows the vendor does not
  list stay as they are, with Connect, and are retried on the next open.
  They are never deleted, and no row is created for a vendor account we have
  no row for.

  The URL keeps the parameters after landing (a nested LiveView cannot patch
  the host's URL), so a reload replays the return. That is safe because
  `complete_connect/4` is idempotent: a ref already on the row answers
  "already connected" with no write.
  """
  use PlatformWeb, :live_view

  alias Phoenix.LiveView.JS

  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Social
  alias Platform.Accounts.User
  alias Platform.Social.{Account, Approvals, Publisher, Secrets}
  alias PlatformWeb.SocialCalendar, as: Cal

  @tabs ~w(queue calendar connections settings)

  @impl true
  def mount(_params, session, socket) do
    user = Platform.Accounts.get_user(session["user_id"])
    profiles = if user, do: Social.list_profiles_for_user(user), else: []

    socket =
      socket
      |> assign(:user, user)
      |> assign(:tab, "queue")
      |> assign(:queue_canvas_ids, [])
      |> assign(:week_start, Cal.week_start(Date.utc_today()))
      |> assign(:detail, nil)
      |> assign(:notice, nil)
      |> assign(:notice_tone, :info)
      |> assign(:removing, nil)
      |> assign(:create_open?, false)
      |> assign_creatable(creatable_orgs(user))
      |> assign_profiles(profiles)
      |> assign(:zernio_human?, human?(user))
      |> assign(:zernio_mode, :idle)
      |> assign(:zernio_nonce, 0)
      |> assign_zernio()

    socket = load_profile(socket, List.first(profiles))

    # The OAuth return: connected mount only (the static render sends no
    # vendor request, so the vendor is asked once), live humans only.
    socket =
      if connected?(socket) and human?(user),
        do: handle_return(socket, profiles, return_params(session["query"])),
        else: socket

    {:ok, socket}
  end

  # Create a profile. The user and their creatable orgs are re-read NOW; a
  # viewer who cannot create (an agent, an archived user, no creatable org)
  # is refused with no write. Only `name` and `home_url` come from params,
  # plus an `org_id` that must be in the fresh creatable set.
  @impl true
  def handle_event("create_profile", %{"profile" => params}, socket) when is_map(params) do
    user = fresh_user(socket)
    orgs = creatable_orgs(user)
    socket = assign_creatable(socket, orgs)

    case target_org(orgs, params) do
      nil ->
        {:noreply, assign(socket, :create_open?, false)}

      org_id ->
        attrs = %{
          name: params["name"],
          home_url: blank_to_nil(params["home_url"]),
          approver_user_ids: [user.id]
        }

        case Social.create_profile(org_id, attrs) do
          {:ok, profile} ->
            profiles = visible_profiles(socket)

            {:noreply,
             socket
             |> assign_profiles(profiles)
             |> load_profile(profile)
             |> assign(:tab, "queue")
             |> assign(:create_open?, false)
             |> assign(:create_form, blank_create_form())}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :create_form, create_error_form(changeset))}

          {:error, _} ->
            {:noreply,
             assign(
               socket,
               :create_form,
               create_error_form(params, "That profile could not be created. Try again.")
             )}
        end
    end
  end

  def handle_event("create_profile", _params, socket), do: {:noreply, socket}

  def handle_event("open_create", _params, socket) do
    socket = assign_creatable(socket, creatable_orgs(fresh_user(socket)))

    {:noreply,
     socket
     |> assign(:create_open?, socket.assigns.can_create?)
     |> assign(:create_form, blank_create_form())}
  end

  def handle_event("close_create", _params, socket),
    do: {:noreply, assign(socket, :create_open?, false)}

  def handle_event("switch_profile", %{"profile_id" => id}, socket) do
    # Re-read what this user may see NOW; an id outside it changes nothing.
    profiles = visible_profiles(socket)
    socket = assign_profiles(socket, profiles)

    case Enum.find(profiles, &(&1.id == id)) do
      nil -> {:noreply, socket}
      profile -> {:noreply, load_profile(socket, profile)}
    end
  end

  def handle_event("select_tab", %{"tab" => tab}, socket) when tab in @tabs,
    do: {:noreply, socket |> assign(:tab, tab) |> maybe_reconcile()}

  def handle_event("select_tab", _params, socket), do: {:noreply, socket}

  def handle_event("week_" <> which, _params, socket) when which in ~w(prev this next) do
    week =
      case which do
        "prev" -> Date.add(socket.assigns.week_start, -7)
        "next" -> Date.add(socket.assigns.week_start, 7)
        "this" -> Cal.week_start(Date.utc_today())
      end

    {:noreply, socket |> assign(:week_start, week) |> load_calendar()}
  end

  # Read-only post detail. The post is re-read through the org scope and
  # must sit on one of the CURRENT profile's accounts; its body is shown
  # only to an approver of the profile (approver_check/3 == :ok) or once
  # the post is published.
  def handle_event("open_post", %{"id" => id}, socket) do
    {:noreply, assign(socket, :detail, detail_for(socket, id))}
  end

  def handle_event("close_post", _params, socket), do: {:noreply, assign(socket, :detail, nil)}

  # Connect / Reconnect: an approver of the profile only (re-checked here,
  # server-side), through the configured Publisher's connect_url/2 with this
  # install's own /m/social as the redirect. The vendor URL is never logged.
  def handle_event("connect_account", %{"id" => id}, socket) do
    with {:ok, profile, _user} <- authorize(socket),
         %Account{} = account <- profile_account(profile, id),
         publisher when is_atom(publisher) <- Publisher.impl(),
         {:ok, profile} <- Social.ensure_provider_profile(profile.org_id, profile),
         {:ok, url} <-
           publisher.connect_url(account, redirect_url: own_url("/m/social"), profile: profile) do
      {:noreply, redirect(socket, external: url)}
    else
      {:error, :publisher_not_configured} ->
        {:noreply, notice(socket, "Publishing isn't configured on this install.")}

      {:error, :not_an_approver} ->
        {:noreply, notice(socket, "Only an approver of this profile can change it.")}

      {:error, {:profile_name_taken, _name} = reason} ->
        {:noreply, notice(socket, add_error_copy(reason))}

      _ ->
        {:noreply, notice(socket, "That account could not be connected. Try again.")}
    end
  end

  # "+ Add account" opens the picker; it only opens for someone who can edit
  # (rendering only: add_account re-checks).
  def handle_event("open_add_account", _params, socket) do
    {:noreply,
     socket
     |> assign(:add_open?, add_allowed?(socket.assigns))
     |> assign(:add_form, add_form(socket.assigns.connectable_platforms))}
  end

  def handle_event("close_add_account", _params, socket),
    do: {:noreply, assign(socket, :add_open?, false)}

  # Add an account on `platform`: an approver of the CURRENT profile only
  # (authorize/1 here, approver_check/3 again inside Social.add_account/4),
  # which ensures the vendor profile BEFORE any row is written. Then OAuth
  # starts at once. A connect failure after the row exists re-streams the
  # rows so it shows with Connect. The vendor URL is never logged.
  def handle_event("add_account", %{"platform" => platform}, socket) when is_binary(platform) do
    with {:ok, profile, user_id} <- authorize(socket),
         {:ok, account, profile} <- Social.add_account(profile.org_id, profile, user_id, platform) do
      socket = socket |> assign(:profile, profile) |> assign(:add_open?, false)

      with publisher when is_atom(publisher) <- Publisher.impl(),
           {:ok, url} <-
             publisher.connect_url(account, redirect_url: own_url("/m/social"), profile: profile) do
        {:noreply, redirect(socket, external: url)}
      else
        _ ->
          {:noreply,
           socket
           |> restream_accounts()
           |> notice("That account could not be connected. Try again.")}
      end
    else
      {:error, reason} -> {:noreply, notice(socket, add_error_copy(reason))}
      _ -> {:noreply, notice(socket, add_error_copy(:unknown))}
    end
  end

  def handle_event("add_account", _params, socket), do: {:noreply, socket}

  # Approval mode is account configuration, not a decision: Approve first or
  # Draft-only, nothing else (Autonomous is dropped). Approvers only.
  def handle_event("set_mode", %{"account_id" => id, "approval_mode" => mode}, socket) do
    with true <- mode in Account.approval_modes(),
         {:ok, profile, _user} <- authorize(socket),
         %Account{} = account <- profile_account(profile, id),
         {:ok, account} <- Social.update_account(profile.org_id, account, %{approval_mode: mode}) do
      {:noreply,
       socket
       |> assign(:notice, nil)
       |> stream_insert(:accounts, account_item(account, socket.assigns.removing))}
    else
      {:error, :not_an_approver} ->
        {:noreply, notice(socket, "Only an approver of this profile can change it.")}

      _ ->
        {:noreply, notice(socket, "That approval mode could not be saved.")}
    end
  end

  # Remove (task 01a14ac6 stage 3): approvers only, re-checked here AND in
  # Social.remove_account/4. `open_remove` shows the inline confirm panel
  # with the real counts from Social.removal_preview/3; one panel is open at
  # a time (opening another re-streams the old row closed).
  def handle_event("open_remove", %{"id" => id}, socket) when is_binary(id) do
    with {:ok, profile, _user} <- authorize(socket),
         {:ok, preview} <- Social.removal_preview(profile.org_id, profile, id) do
      removing = %{account_id: preview.account.id, preview: preview}

      {:noreply,
       socket
       |> close_removal()
       |> assign(:removing, removing)
       |> stream_insert(:accounts, account_item(preview.account, removing))}
    else
      {:error, :not_found} -> {:noreply, account_gone(socket)}
      _ -> {:noreply, notice(socket, "Only an approver of this profile can change it.")}
    end
  end

  def handle_event("cancel_remove", _params, socket),
    do: {:noreply, close_removal(socket)}

  def handle_event("remove_account", %{"id" => id}, socket) when is_binary(id) do
    with {:ok, profile, user_id} <- authorize(socket),
         {:ok, account, result} <- Social.remove_account(profile.org_id, profile, user_id, id) do
      {:noreply,
       socket
       |> assign(:removing, nil)
       |> stream_delete(:accounts, account_item(account, nil))
       |> assign_account_flags()
       |> assign_profiles(visible_profiles(socket))
       |> removed_notice(account, result.vendor)}
    else
      {:error, :not_found} ->
        {:noreply, account_gone(socket)}

      {:error, reason}
      when reason in [:not_an_approver, :not_a_human, :approver_archived, :approver_no_access] ->
        {:noreply, notice(socket, "Only an approver of this profile can change it.")}

      _ ->
        {:noreply, notice(socket, "That account could not be removed. Try again.")}
    end
  end

  def handle_event(event, _params, socket) when event in ~w(open_remove remove_account),
    do: {:noreply, socket}

  def handle_event("validate_settings", %{"profile" => params}, socket) do
    {:noreply,
     assign(socket, :settings_form, settings_form(socket.assigns.profile, params, :validate))}
  end

  def handle_event("save_settings", %{"profile" => params}, socket) do
    with {:ok, profile, _user} <- authorize(socket) do
      attrs = settings_attrs(params, profile, socket.assigns.settings_options)

      case Social.update_profile(profile.org_id, profile, attrs) do
        {:ok, profile} ->
          profiles = visible_profiles(socket)

          {:noreply,
           socket
           |> assign_profiles(profiles)
           |> assign(:profile, profile)
           |> assign(:settings_form, settings_form(profile, %{}))
           |> notice("Settings saved.")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :settings_form, to_form(changeset, as: :profile))}

        {:error, _} ->
          {:noreply, notice(socket, "Those settings could not be saved.")}
      end
    else
      _ -> {:noreply, notice(socket, "Only an approver of this profile can change it.")}
    end
  end

  def handle_event("dismiss_notice", _params, socket),
    do: {:noreply, assign(socket, :notice, nil)}

  # The install's Zernio key. The user is re-read NOW and must be a live
  # human; anyone else (an agent session, nil, an archived user) is refused
  # with nothing written. The submitted value goes straight to Secrets and
  # is dropped: the form is rebuilt empty whatever the outcome.
  def handle_event("save_zernio_key", params, socket) do
    case fresh_user(socket) do
      %User{archived_at: nil} = user ->
        mode =
          case Secrets.put_zernio_api_key(zernio_value(params), user) do
            {:ok, _credential} -> :idle
            {:error, _reason} -> :error
          end

        blocked? = socket.assigns.zernio_blocks_connect?
        socket = socket |> assign(:zernio_mode, mode) |> assign_zernio()

        # Account rows are a stream: Connect/Reconnect re-render only when
        # the rows are re-streamed, so do that when the gate flipped.
        {:noreply,
         if(socket.assigns.zernio_blocks_connect? == blocked?,
           do: socket,
           else: restream_accounts(socket)
         )}

      _not_a_live_human ->
        {:noreply, socket |> assign(:zernio_human?, false) |> assign_zernio()}
    end
  end

  # Replace (set), Try again (failed save) and Cancel only move the row
  # between its states; none of them reads or writes the key.
  def handle_event(event, _params, socket)
      when event in ~w(replace_zernio_key retry_zernio_key cancel_zernio_key) do
    mode = if event == "cancel_zernio_key", do: :idle, else: :edit

    {:noreply,
     if(socket.assigns.zernio_human?,
       do: socket |> assign(:zernio_mode, mode) |> assign_zernio(),
       else: socket
     )}
  end

  # A queued card's canvas changed (a decision here, in chat, or anywhere):
  # the card re-renders from `card_view/2` and the counts are re-read. The
  # row stays in the stream showing the card's decided status until the
  # next profile load.
  @impl true
  def handle_info({:canvas_updated, %{id: canvas_id} = canvas}, socket) do
    if canvas_id in socket.assigns.queue_canvas_ids do
      case Map.get(socket.assigns.queue_cards, canvas_id) do
        nil ->
          :ok

        card_id ->
          send_update(PlatformWeb.SocialCardComponent,
            id: "queue-card-" <> card_id,
            rev: rev_of(canvas.document)
          )
      end

      {:noreply, assign_profiles(socket, visible_profiles(socket))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ONE place a profile becomes current. Every per-profile stream loads here
  # with `reset: true`, so a switch leaves nothing of the previous profile.
  defp load_profile(socket, profile) do
    rows = queue_rows(profile)
    canvas_ids = for %{card: %{canvas_id: id}} <- rows, do: id

    if connected?(socket) do
      Enum.each(socket.assigns.queue_canvas_ids -- canvas_ids, &ChatPubSub.unsubscribe_canvas/1)
      Enum.each(canvas_ids -- socket.assigns.queue_canvas_ids, &ChatPubSub.subscribe_canvas/1)
    end

    socket
    |> assign(:profile, profile)
    |> assign(:detail, nil)
    |> assign(:queue_canvas_ids, canvas_ids)
    |> assign(:queue_cards, Map.new(for %{card: %{} = c} <- rows, do: {c.canvas_id, c.id}))
    |> assign(:queue_empty?, rows == [])
    |> stream(:queue, rows, reset: true)
    |> assign(:notice, nil)
    |> load_calendar()
    |> load_connections()
    |> maybe_reconcile()
  end

  # Connections and Settings for the current profile. `can_edit?` is ONLY
  # for rendering; every write handler re-checks through `authorize/1`.
  defp load_connections(%{assigns: %{profile: nil}} = socket) do
    socket
    |> assign(:removing, nil)
    |> assign(:can_edit?, false)
    |> assign(:accounts_empty?, true)
    |> assign(:pending_accounts?, false)
    |> assign(:connectable_platforms, [])
    |> assign(:add_open?, false)
    |> assign(:add_form, add_form([]))
    |> assign(:settings_options, %{approvers: [], spaces: []})
    |> assign(:settings_form, nil)
    |> stream(:accounts, [], reset: true)
  end

  defp load_connections(%{assigns: %{profile: profile}} = socket) do
    accounts = Social.list_accounts(profile.org_id, profile_id: profile.id)
    can_edit? = match?({:ok, _, _}, authorize(socket))

    platforms = Social.connectable_platforms()

    socket
    |> assign(:removing, nil)
    |> assign(:can_edit?, can_edit?)
    |> assign(:accounts_empty?, accounts == [])
    |> assign(:pending_accounts?, Enum.any?(accounts, &never_connected?/1))
    |> assign(:connectable_platforms, platforms)
    |> assign(:add_open?, false)
    |> assign(:add_form, add_form(platforms))
    |> assign(:settings_options, settings_options(profile, can_edit?))
    |> assign(:settings_form, settings_form(profile, %{}))
    |> stream(:accounts, Enum.map(accounts, &account_item(&1, nil)), reset: true)
  end

  # A stream row; `removal` is the open confirm panel's preview, else nil.
  defp account_item(account, %{account_id: id, preview: preview}) when id == account.id,
    do: %{id: account.id, account: account, removal: preview}

  defp account_item(account, _removing), do: %{id: account.id, account: account, removal: nil}

  # Closes the open confirm panel (if any) by re-streaming its row as read
  # now; a row that is no longer live is dropped from the stream.
  defp close_removal(%{assigns: %{removing: %{account_id: id}, profile: %{} = profile}} = socket) do
    socket = assign(socket, :removing, nil)

    case profile_account(profile, id) do
      %Account{} = account -> stream_insert(socket, :accounts, account_item(account, nil))
      nil -> stream_delete(socket, :accounts, %{id: id})
    end
  end

  defp close_removal(socket), do: assign(socket, :removing, nil)

  defp account_gone(socket) do
    socket
    |> assign(:removing, nil)
    |> restream_accounts()
    |> notice("That account is already gone.")
  end

  defp assign_account_flags(%{assigns: %{profile: %{} = profile}} = socket) do
    accounts = Social.list_accounts(profile.org_id, profile_id: profile.id)

    socket
    |> assign(:accounts_empty?, accounts == [])
    |> assign(:pending_accounts?, Enum.any?(accounts, &never_connected?/1))
  end

  defp assign_account_flags(socket), do: socket

  defp removed_notice(socket, _account, {:unconfirmed, _reason}) do
    notice(
      socket,
      "Removed here. Zernio didn't confirm the disconnect, so check the account in Zernio.",
      :warning
    )
  end

  defp removed_notice(socket, account, _vendor),
    do: notice(socket, "Removed #{removal_label(account)}.")

  # "LINKEDIN @htc-company": the platform upper-cased, then the handle as
  # stored (omitted when nil or blank).
  defp removal_label(%Account{platform: platform, handle: handle}) do
    [String.upcase(platform || ""), handle]
    |> Enum.reject(&(is_nil(&1) or String.trim(&1) == ""))
    |> Enum.join(" ")
  end

  defp restream_accounts(%{assigns: %{profile: nil}} = socket), do: socket

  defp restream_accounts(%{assigns: %{profile: profile}} = socket) do
    accounts = Social.list_accounts(profile.org_id, profile_id: profile.id)

    socket
    |> assign(:accounts_empty?, accounts == [])
    |> assign(:pending_accounts?, Enum.any?(accounts, &never_connected?/1))
    |> stream(:accounts, Enum.map(accounts, &account_item(&1, socket.assigns.removing)),
      reset: true
    )
  end

  # The rows `Platform.Social.reconcile_accounts/3` can fill: never connected
  # (no status, no vendor ref). Mirrors the context's own predicate.
  defp never_connected?(%Account{status: nil, provider_account_ref: nil, archived_at: nil}),
    do: true

  defp never_connected?(_account), do: false

  # ── Reconcile on opening Connections (task 01a14807) ────────────────

  @approver_refusals [:not_an_approver, :not_a_human, :approver_archived, :approver_no_access]

  # Picks up accounts connected at the vendor whose return never reached us.
  # Runs only on the Connections tab, on a connected socket, for a viewer who
  # passes `authorize/1`, on a profile with a vendor ref, while a
  # never-connected row is listed. `reconcile_accounts/3` re-checks the
  # approver and the ref and sends nothing when no row is pending, so once
  # every row is connected this costs zero requests. Synchronous: the
  # publisher's 5s receive_timeout bounds how long the click can block.
  defp maybe_reconcile(%{assigns: %{tab: "connections", pending_accounts?: true}} = socket) do
    with true <- connected?(socket),
         {:ok, fresh, user_id} <- authorize(socket),
         ref when is_binary(ref) and ref != "" <- fresh.provider_profile_ref do
      reconciled(socket, Social.reconcile_accounts(fresh.org_id, fresh, user_id))
    else
      _ -> socket
    end
  end

  defp maybe_reconcile(socket), do: socket

  defp reconciled(socket, {:ok, %{connected: [_ | _] = accounts}}) do
    n = length(accounts)
    noun = if n == 1, do: "account", else: "accounts"
    names = Enum.map_join(accounts, ", ", &account_label/1)

    socket
    |> restream_accounts()
    |> notice("Picked up #{n} connected #{noun} from Zernio: #{names}.")
  end

  defp reconciled(socket, {:ok, _nothing_new}), do: socket

  # The key alert already says it; refusals and an unlinked profile never
  # reach here for an approver on a linked profile, and say nothing if they do.
  defp reconciled(socket, {:error, reason})
       when reason in [:credentials_unavailable, :profile_not_linked, :publisher_not_configured] or
              reason in @approver_refusals,
       do: socket

  defp reconciled(socket, _error),
    do: notice(socket, "Couldn't check Zernio for connected accounts. Try again.")

  defp account_label(%Account{platform: platform, handle: handle})
       when is_binary(handle) and handle != "",
       do: "#{platform_label(platform)} #{handle}"

  defp account_label(%Account{platform: platform}), do: platform_label(platform)

  # ── Add account ─────────────────────────────────────────────────────

  # Display names only; the option VALUES always come from
  # Social.connectable_platforms/0.
  @platform_labels %{
    "linkedin" => "LinkedIn",
    "x" => "X",
    "tiktok" => "TikTok",
    "instagram" => "Instagram",
    "youtube" => "YouTube"
  }

  defp platform_options(platforms),
    do: Enum.map(platforms, &{Map.get(@platform_labels, &1, &1), &1})

  defp add_form(platforms), do: to_form(%{"platform" => List.first(platforms)})

  defp add_allowed?(assigns) do
    assigns.can_edit? and not assigns.zernio_blocks_connect? and
      assigns.connectable_platforms != []
  end

  defp add_error_copy(reason) when reason in @approver_refusals,
    do: "Only an approver of this profile can change it."

  defp add_error_copy(:unsupported_platform),
    do: "That platform can't be connected on this install."

  defp add_error_copy(:credentials_unavailable), do: "Add the Zernio API key in Settings first."

  defp add_error_copy({:profile_name_taken, name}),
    do:
      "Zernio already has a profile named #{name}. Rename this profile in Settings and try again."

  defp add_error_copy(_reason), do: "Couldn't set up this profile at Zernio. Try again."

  # The user, re-read now, must pass approver_check/3 on the CURRENT profile,
  # itself re-read through the scope.
  defp authorize(%{assigns: %{profile: %{} = profile, user: %{id: user_id}}}) do
    with %Social.Profile{} = fresh <- Social.get_profile(profile.org_id, profile.id),
         :ok <- Social.approver_check(fresh.org_id, fresh, user_id) do
      {:ok, fresh, user_id}
    else
      _ -> {:error, :not_an_approver}
    end
  end

  defp authorize(_socket), do: {:error, :not_an_approver}

  defp profile_account(profile, id) do
    case Social.get_account(profile.org_id, id) do
      %Account{profile_id: profile_id, archived_at: nil} = account
      when profile_id == profile.id ->
        account

      _ ->
        nil
    end
  end

  # ── OAuth return (task 01a14807) ─────────────────────────────────────

  @vendor_id ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @error_code ~r/\A[a-z0-9_]{1,64}\z/

  # The ONE parser for the host's forwarded query (untrusted strings).
  # Only profileId, accountId and error are read; username, error_message
  # and every other key are ignored (the handle comes from the vendor list).
  defp return_params(%{"error" => error} = query) when is_binary(error) do
    {:return_error, %{code: shaped(error, @error_code), profile_ref: shaped(query["profileId"])}}
  end

  defp return_params(%{} = query)
       when is_map_key(query, "connected") or is_map_key(query, "profileId") or
              is_map_key(query, "accountId") do
    case {shaped(query["profileId"]), shaped(query["accountId"])} do
      {profile_ref, account_ref} when is_binary(profile_ref) and is_binary(account_ref) ->
        {:return_connected, %{profile_ref: profile_ref, account_ref: account_ref}}

      _ ->
        :return_malformed
    end
  end

  defp return_params(_query), do: :no_return

  defp shaped(value, pattern \\ @vendor_id)
  defp shaped(value, pattern) when is_binary(value), do: if(value =~ pattern, do: value)
  defp shaped(_value, _pattern), do: nil

  # Only among the viewer's VISIBLE profiles: another org's ref is no match.
  defp return_profile(profiles, ref) when is_binary(ref),
    do: Enum.find(profiles, &(&1.provider_profile_ref == ref))

  defp return_profile(_profiles, _ref), do: nil

  defp handle_return(socket, _profiles, :no_return), do: socket

  defp handle_return(socket, _profiles, :return_malformed) do
    socket
    |> assign(:tab, "connections")
    |> notice("That connection couldn't be read. Nothing changed. Try Connect again.")
  end

  defp handle_return(socket, profiles, {:return_error, %{code: code, profile_ref: ref}}) do
    socket =
      case return_profile(profiles, ref) do
        nil -> socket
        profile -> load_profile(socket, profile)
      end

    reason = if code, do: " (#{code})", else: ""

    socket
    |> assign(:tab, "connections")
    |> notice("The account wasn't connected#{reason}. Try Connect again.")
  end

  defp handle_return(socket, profiles, {:return_connected, params}) do
    case return_profile(profiles, params.profile_ref) do
      nil ->
        socket
        |> assign(:tab, "connections")
        |> notice("That connection doesn't match a profile you can manage. Nothing changed.")

      profile ->
        # load_profile/2 resets :notice, so the notice is set AFTER it.
        socket = socket |> load_profile(profile) |> assign(:tab, "connections")

        result =
          with {:ok, fresh, user_id} <- authorize(socket) do
            Social.complete_connect(fresh.org_id, fresh, user_id, %{
              account_ref: params.account_ref
            })
          end

        socket |> restream_accounts() |> notice(return_copy(result, profile))
    end
  end

  defp return_copy({:ok, account, :connected}, _profile) do
    case account.handle do
      handle when is_binary(handle) and handle != "" ->
        "#{platform_label(account.platform)} connected as #{handle}."

      _ ->
        "#{platform_label(account.platform)} connected."
    end
  end

  defp return_copy({:ok, account, :already_connected}, _profile),
    do: "#{platform_label(account.platform)} is already connected."

  defp return_copy({:error, reason}, profile)
       when reason in [:not_listed, :ref_in_use, :no_pending_account],
       do:
         "Zernio didn't confirm that account for #{profile.name}. Nothing changed. Try Connect again."

  defp return_copy({:error, reason}, _profile) when reason in @approver_refusals,
    do: "Only an approver of this profile can change it."

  defp return_copy({:error, :credentials_unavailable}, _profile),
    do: "Add the Zernio API key in Settings first."

  defp return_copy(_result, _profile), do: "Couldn't check the connection with Zernio. Try again."

  defp platform_label(platform), do: Map.get(@platform_labels, platform, platform)

  defp own_url(path), do: PlatformWeb.Endpoint.url() <> path

  # `tone` is :info (the plain notice line) or :warning (alert-warning).
  defp notice(socket, text, tone \\ :info),
    do: socket |> assign(:notice, text) |> assign(:notice_tone, tone)

  # Who the approver picker offers (HUMAN users who are internal members of
  # the profile's org; agents are not users, so never offered) and the org's
  # channels by name. Only built for someone who can edit.
  defp settings_options(_profile, false), do: %{approvers: [], spaces: []}

  defp settings_options(profile, true) do
    approvers =
      Platform.Accounts.list_users()
      |> Enum.filter(&Platform.Tenancy.internal_member?(&1, profile.org_id))

    spaces =
      [kind: "channel"]
      |> Platform.Chat.list_spaces()
      |> Enum.filter(&(&1.org_id == profile.org_id))
      |> Enum.sort_by(&String.downcase(&1.name || ""))

    %{approvers: approvers, spaces: spaces}
  end

  defp settings_form(profile, params, action \\ nil) do
    data = %{
      "home_url" => profile.home_url,
      "voice_notes" => profile.voice_notes,
      "default_hashtags" => Enum.join(profile.default_hashtags || [], ", "),
      "approver_user_ids" => profile.approver_user_ids || [],
      "space_id" => profile.space_id
    }

    to_form(Map.merge(data, params), as: :profile, action: action)
  end

  # Only the five settings fields are taken; approver ids and the space must
  # be among what the picker offered (server-side, not trusted from the client).
  defp settings_attrs(params, profile, %{approvers: approvers, spaces: spaces}) do
    offered_users = MapSet.new(approvers, & &1.id)
    offered_spaces = MapSet.new(spaces, & &1.id)

    approver_ids =
      params
      |> Map.get("approver_user_ids", [])
      |> List.wrap()
      |> Enum.filter(&MapSet.member?(offered_users, &1))
      |> Enum.uniq()

    space_id =
      case params["space_id"] do
        id when is_binary(id) ->
          if MapSet.member?(offered_spaces, id), do: id, else: profile.space_id

        _ ->
          profile.space_id
      end

    hashtags =
      (params["default_hashtags"] || "")
      |> String.split([",", " "], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    %{
      home_url: blank_to_nil(params["home_url"]),
      voice_notes: blank_to_nil(params["voice_notes"]),
      default_hashtags: hashtags,
      approver_user_ids: approver_ids,
      space_id: space_id
    }
  end

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_), do: nil

  # The week's calendar for the current profile: one row per non-archived
  # account (desktop) and one block per day with items (mobile agenda).
  # Both re-stream with `reset: true` on a profile switch or a week change.
  defp load_calendar(%{assigns: %{profile: nil}} = socket) do
    socket
    |> assign(:calendar_empty?, true)
    |> stream(:calendar_rows, [], reset: true)
    |> stream(:agenda_days, [], reset: true)
  end

  defp load_calendar(%{assigns: %{profile: profile, week_start: monday}} = socket) do
    accounts = Social.list_accounts(profile.org_id, profile_id: profile.id)
    items = Cal.items(profile, accounts, monday)

    socket
    |> assign(:detail, nil)
    |> assign(:calendar_empty?, items == [])
    |> stream(:calendar_rows, Cal.rows(accounts, items, monday), reset: true)
    |> stream(:agenda_days, Cal.agenda(items, monday), reset: true)
  end

  defp detail_for(%{assigns: %{profile: %{} = profile, user: %{id: user_id}}}, id) do
    with %Social.Post{} = post <- Social.get_post(profile.org_id, id),
         %Social.Account{profile_id: profile_id} = account when profile_id == profile.id <-
           Social.get_account(profile.org_id, post.account_id),
         true <- post.status in Cal.statuses() do
      show_body? =
        post.status == "published" or
          Social.approver_check(profile.org_id, profile, user_id) == :ok

      %{
        post: post,
        account: account,
        at: post.scheduled_at || post.approved_at,
        show_body?: show_body?
      }
    else
      _ -> nil
    end
  end

  defp detail_for(_socket, _id), do: nil

  # The profile's needs_approval posts, each with its live approval card
  # (read only) and that card's canvas revision. The rows carry no decision
  # state of their own: the embedded component asks `card_view/2`.
  defp queue_rows(nil), do: []

  defp queue_rows(profile) do
    profile.org_id
    |> Social.list_posts(profile_id: profile.id, status: "needs_approval")
    |> Enum.map(fn post ->
      card = Approvals.live_card(post.id)
      %{id: post.id, post: post, card: card, rev: card && card_rev(card)}
    end)
  end

  defp card_rev(card) do
    case Platform.Chat.get_canvas(card.canvas_id) do
      %{document: document} -> rev_of(document)
      _ -> nil
    end
  end

  defp rev_of(%{"root" => %{"props" => %{"rev" => rev}}}) when is_integer(rev), do: rev
  defp rev_of(_), do: nil

  # ── Create ──────────────────────────────────────────────────────────

  defp fresh_user(%{assigns: %{user: %{id: id}}}), do: Platform.Accounts.get_user(id)
  defp fresh_user(_socket), do: nil

  # ── Zernio key ──────────────────────────────────────────────────────

  defp human?(%User{archived_at: nil}), do: true
  defp human?(_user), do: false

  defp zernio_value(%{"zernio_key" => %{"api_key" => value}}) when is_binary(value), do: value
  defp zernio_value(_params), do: nil

  # Re-reads the key's status (Vault metadata only, nothing decrypted) and
  # rebuilds the form EMPTY under a fresh id, so no submitted value survives
  # in assigns or in the DOM. `zernio_blocks_connect?` is true only while the
  # Zernio publisher is selected and no key is set (the Fake needs no key).
  defp assign_zernio(socket) do
    status = zernio_status()

    socket
    |> assign(:zernio_status, status)
    |> assign(:zernio_form, to_form(%{"api_key" => ""}, as: :zernio_key))
    |> update(:zernio_nonce, &(&1 + 1))
    |> assign(
      :zernio_blocks_connect?,
      status == :not_set and Publisher.impl() == Platform.Social.Publisher.Zernio
    )
  end

  defp zernio_status do
    case Secrets.zernio_key_status() do
      :not_set ->
        :not_set

      {:set, %{changed_at: at, changed_by_user_id: user_id}} ->
        {:set, %{by: setter_name(user_id), on: Calendar.strftime(at, "%-d %b")}}
    end
  end

  defp setter_name(user_id) when is_binary(user_id) do
    case Platform.Accounts.get_user(user_id) do
      %User{name: name} when is_binary(name) and name != "" -> name
      %User{email: email} when is_binary(email) -> email
      _ -> nil
    end
  end

  defp setter_name(_user_id), do: nil

  # The ONE place that decides where `user` may create a profile (keep it
  # single: when RBAC gates this, this body is the edit). The orgs of the
  # user's NON-external memberships in live orgs, intersected with what the
  # swap points allow (`Platform.Tenancy.visibility/1` through
  # `Platform.Social.visible_orgs/1`). nil, an archived user or an agent id
  # (which `get_user/1` answers nil for) creates nowhere.
  defp creatable_orgs(%Platform.Accounts.User{archived_at: nil} = user) do
    allowed =
      case Platform.Tenancy.visibility(user) do
        :root_all -> Social.visible_orgs(:root)
        {:orgs, ids} -> Enum.flat_map(ids, &Social.visible_orgs/1)
        _ -> []
      end

    user
    |> Platform.Tenancy.list_user_memberships()
    |> Enum.filter(&match?(%{external: false, org: %{archived_at: nil}}, &1))
    |> Enum.filter(&(allowed == :all or &1.org_id in allowed))
    |> Enum.map(&%{id: &1.org_id, name: &1.org.name})
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&String.downcase(&1.name || ""))
  end

  defp creatable_orgs(_user), do: []

  # `can_create?` is for rendering only; the handler re-resolves.
  defp assign_creatable(socket, orgs) do
    socket
    |> assign(:creatable_orgs, orgs)
    |> assign(:can_create?, orgs != [])
    |> assign_new(:create_form, &blank_create_form/0)
  end

  # A client org id is honoured only if it is in the fresh creatable set.
  # Without one, a user with exactly one creatable org creates there; with
  # several, the form carries the Org select and a missing id is refused.
  defp target_org(orgs, %{"org_id" => org_id}) when is_binary(org_id) do
    if Enum.any?(orgs, &(&1.id == org_id)), do: org_id
  end

  defp target_org([%{id: org_id}], params) when not is_map_key(params, "org_id"), do: org_id
  defp target_org(_orgs, _params), do: nil

  defp blank_create_form, do: to_form(%{"name" => "", "home_url" => ""}, as: :profile)

  # The unique constraint on [:org_id, :name] lands on :org_id (the first
  # field); a form that only shows :name errors would swallow it, so it is
  # moved onto Name with the canvas copy.
  defp create_error_form(%Ecto.Changeset{} = changeset) do
    name = Ecto.Changeset.get_field(changeset, :name)

    {unique, rest} =
      Enum.split_with(changeset.errors, fn
        {:org_id, {_msg, opts}} -> opts[:constraint] == :unique
        _ -> false
      end)

    errors =
      if unique == [],
        do: rest,
        else: [{:name, {"A profile called #{name} already exists.", []}} | rest]

    to_form(%{changeset | errors: errors}, as: :profile, action: :insert)
  end

  defp create_error_form(params, message) do
    to_form(
      %{"name" => params["name"] || "", "home_url" => params["home_url"] || ""},
      as: :profile,
      errors: [name: {message, []}],
      action: :insert
    )
  end

  defp visible_profiles(%{assigns: %{user: %{id: id}}}) do
    case Platform.Accounts.get_user(id) do
      nil -> []
      user -> Social.list_profiles_for_user(user)
    end
  end

  defp visible_profiles(_socket), do: []

  defp assign_profiles(socket, profiles) do
    socket
    |> assign(:profiles, profiles)
    |> assign(:counts, Social.needs_approval_counts(Enum.map(profiles, & &1.id)))
  end

  defp count(counts, %{id: id}), do: Map.get(counts, id, 0)
  defp count(_counts, _), do: 0

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full min-h-0 flex-col" data-role="social-tab">
      <%= if @profile do %>
        <header class="border-b border-base-300 px-4 pt-4 sm:px-6">
          <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
            <form id="social-profile-switcher" phx-change="switch_profile" class="min-w-0">
              <label for="social-profile-select" class="sr-only">Profile</label>
              <select
                id="social-profile-select"
                name="profile_id"
                class="select select-ghost w-auto max-w-full bg-base-100 text-xl font-bold"
                data-role="social-profile-select"
              >
                <option
                  :for={profile <- @profiles}
                  value={profile.id}
                  selected={profile.id == @profile.id}
                  data-role="social-profile-option"
                  data-count={count(@counts, profile)}
                >
                  {profile.name} {count(@counts, profile)}
                </option>
              </select>
            </form>
            <span
              :if={count(@counts, @profile) > 0}
              class="badge badge-warning whitespace-nowrap"
              data-role="social-needs-approval"
            >
              {count(@counts, @profile)} need approval
            </span>
            <span
              :if={count(@counts, @profile) == 0}
              class="whitespace-nowrap text-sm text-base-content/70"
              data-role="social-needs-approval"
            >
              0 need approval
            </span>
            <button
              :if={@can_create?}
              type="button"
              class="btn btn-ghost btn-sm whitespace-nowrap"
              phx-click={if @create_open?, do: "close_create", else: "open_create"}
              aria-expanded={to_string(@create_open?)}
              aria-controls="social-create-panel"
              data-role="social-new-profile"
            >
              + New profile
            </button>
          </div>

          <%!-- + New profile: inline under the header from sm up, a bottom
               sheet below sm. --%>
          <div :if={@can_create? and @create_open?} phx-window-keydown="close_create" phx-key="escape">
            <button
              type="button"
              class="fixed inset-0 z-30 bg-base-content/40 sm:hidden"
              phx-click="close_create"
              aria-label="Close"
            >
            </button>
            <div
              id="social-create-panel"
              class="fixed inset-x-0 bottom-0 z-40 max-h-[85vh] overflow-y-auto rounded-t-2xl border border-base-300 bg-base-100 p-4 sm:static sm:z-auto sm:mt-3 sm:max-w-xl sm:rounded-xl"
              data-role="social-create-panel"
            >
              <div class="mb-3 flex items-center justify-between gap-2">
                <h2 class="text-lg font-semibold">New profile</h2>
                <button
                  type="button"
                  class="btn btn-ghost btn-sm btn-square"
                  phx-click="close_create"
                  aria-label="Close"
                >
                  <.icon name="hero-x-mark" class="size-5" />
                </button>
              </div>
              <.create_form form={@create_form} orgs={@creatable_orgs} focus?={true} />
            </div>
          </div>

          <nav
            class="tabs tabs-border -mb-px mt-3 flex-nowrap overflow-x-auto whitespace-nowrap"
            role="tablist"
            aria-label="Social sections"
            data-role="social-tabs"
          >
            <button
              :for={{key, label} <- tab_labels(@counts, @profile)}
              type="button"
              role="tab"
              class={[
                "tab shrink-0",
                if(@tab == key, do: "tab-active", else: "text-base-content/70!")
              ]}
              aria-selected={to_string(@tab == key)}
              phx-click="select_tab"
              phx-value-tab={key}
              data-role="social-tab-button"
              data-tab={key}
            >
              {label}
            </button>
          </nav>
        </header>

        <section
          class="min-h-0 flex-1 overflow-y-auto px-4 py-4 sm:px-6"
          data-role="social-tab-body"
          data-tab={@tab}
        >
          <%!-- Every pane stays in the DOM (hidden when inactive) so its
               stream survives a tab change. --%>
          <div class={[@tab != "queue" && "hidden"]} data-pane="queue">
            <div :if={@queue_empty?} class="space-y-3">
              <p class="text-base-content/70" data-role="social-empty">
                {empty_queue_copy(@profile, @accounts_empty?)}
              </p>
              <button
                :if={@accounts_empty?}
                type="button"
                class="btn btn-outline btn-sm"
                phx-click="select_tab"
                phx-value-tab="connections"
                data-role="social-go-connections"
              >
                Go to Connections
              </button>
            </div>
            <ul id="social-queue" phx-update="stream" class="space-y-3" data-role="social-queue">
              <li :for={{dom_id, row} <- @streams.queue} id={dom_id} data-role="social-queue-row">
                <%= if row.card do %>
                  <.live_component
                    module={PlatformWeb.SocialCardComponent}
                    id={"queue-card-" <> row.card.id}
                    card_id={row.card.id}
                    rev={row.rev}
                    canvas_id={row.card.canvas_id}
                    viewer={{:user, @user.id}}
                  />
                <% else %>
                  <p
                    class="rounded-xl border border-base-300 bg-base-100 p-3 text-sm text-base-content/70"
                    data-role="social-queue-waiting"
                  >
                    Waiting for its approval card.
                  </p>
                <% end %>
              </li>
            </ul>
          </div>
          <div class={[@tab != "calendar" && "hidden"]} data-pane="calendar">
            <.calendar
              profile={@profile}
              week_start={@week_start}
              empty?={@calendar_empty?}
              rows={@streams.calendar_rows}
              agenda={@streams.agenda_days}
            />
          </div>
          <div class={[@tab != "connections" && "hidden"]} data-pane="connections">
            <.notice_line notice={@notice} tone={@notice_tone} />
            <div
              :if={@zernio_blocks_connect?}
              role="status"
              class="alert alert-warning mb-3 flex flex-wrap items-center justify-between gap-2 text-sm"
              data-role="social-zernio-required"
            >
              <span class="inline-flex items-start gap-2">
                <.icon name="hero-exclamation-triangle-micro" class="mt-0.5 size-4 shrink-0" />
                Add the Zernio API key in Settings before connecting accounts.
              </span>
              <button
                type="button"
                class="btn btn-sm"
                phx-click="select_tab"
                phx-value-tab="settings"
                data-role="social-zernio-go-settings"
              >
                Go to Settings
              </button>
            </div>
            <p :if={@accounts_empty?} class="mb-3 text-base-content/70" data-role="social-empty">
              No accounts connected for {@profile.name} yet
            </p>
            <.add_account
              :if={@can_edit? and not @zernio_blocks_connect? and @connectable_platforms != []}
              open?={@add_open?}
              form={@add_form}
              options={platform_options(@connectable_platforms)}
            />
            <ul
              id="social-accounts"
              phx-update="stream"
              class="divide-y divide-base-300 rounded-lg border border-base-300 bg-base-100"
              data-role="social-accounts"
            >
              <li
                :for={{dom_id, row} <- @streams.accounts}
                id={dom_id}
                class="flex flex-wrap items-center gap-x-3 gap-y-2 px-3 py-2"
                data-role="social-account-row"
              >
                <.account_row
                  account={row.account}
                  can_edit?={@can_edit?}
                  can_connect?={@can_edit? and not @zernio_blocks_connect?}
                />
                <.remove_panel
                  :if={@can_edit? and row.removal}
                  account={row.account}
                  preview={row.removal}
                />
              </li>
            </ul>
          </div>
          <div class={[@tab != "settings" && "hidden"]} data-pane="settings">
            <.notice_line notice={@notice} tone={@notice_tone} />
            <.zernio_key
              :if={@zernio_human?}
              status={@zernio_status}
              mode={@zernio_mode}
              form={@zernio_form}
              nonce={@zernio_nonce}
            />
            <.settings
              profile={@profile}
              form={@settings_form}
              can_edit?={@can_edit?}
              options={@settings_options}
            />
          </div>
        </section>
        <.post_detail :if={@detail} detail={@detail} />
      <% else %>
        <%= if @can_create? do %>
          <div class="px-4 py-8 sm:px-6 sm:py-12">
            <section
              class="mx-auto max-w-xl rounded-xl border border-base-300 bg-base-100 p-4 sm:p-6"
              data-role="social-create"
            >
              <h2 class="text-lg font-semibold" data-role="social-create-heading">
                Set up your first social profile
              </h2>
              <p class="mt-1 mb-4 text-base-content/70" data-role="social-create-explanation">
                A profile is a brand or person you post for. You'll be its first approver.
              </p>
              <.create_form form={@create_form} orgs={@creatable_orgs} focus?={true} />
            </section>
          </div>
        <% else %>
          <div class="px-4 py-12 text-center sm:px-6">
            <p class="text-base-content/70" data-role="social-no-profiles">
              No social profiles yet. Ask an org member to set one up.
            </p>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :orgs, :list, required: true
  attr :focus?, :boolean, default: false

  # The two create fields (plus Org only when the user has several creatable
  # orgs). Errors render inline under their field.
  defp create_form(assigns) do
    assigns =
      assigns
      |> assign(:name_errors, field_errors(assigns.form[:name]))
      |> assign(:home_errors, field_errors(assigns.form[:home_url]))

    ~H"""
    <.form
      for={@form}
      id="social-create-form"
      phx-submit="create_profile"
      class="space-y-3"
      data-role="social-create-form"
    >
      <div :if={length(@orgs) > 1} class="fieldset py-0">
        <label for="social-create-org" class="label mb-1 font-medium">Org</label>
        <select
          id="social-create-org"
          name={@form[:org_id].name}
          class="select w-full"
          data-role="social-create-org"
        >
          <option
            :for={org <- @orgs}
            value={org.id}
            selected={org.id == @form[:org_id].value}
          >
            {org.name}
          </option>
        </select>
      </div>
      <div class="fieldset py-0">
        <label for="social-create-name" class="label mb-1 font-medium">Name</label>
        <input
          type="text"
          id="social-create-name"
          name={@form[:name].name}
          value={@form[:name].value}
          required
          maxlength="255"
          autocomplete="off"
          phx-mounted={@focus? && JS.focus()}
          class={["input w-full", @name_errors != [] && "input-error"]}
          aria-invalid={to_string(@name_errors != [])}
          aria-describedby={@name_errors != [] && "social-create-error"}
          data-role="social-create-name"
        />
        <p
          :for={msg <- @name_errors}
          id="social-create-error"
          role="alert"
          class="mt-1.5 flex items-center gap-1.5 text-sm text-base-content"
          data-role="social-create-error"
        >
          <.icon name="hero-exclamation-circle" class="size-4 shrink-0 text-error" />
          {msg}
        </p>
      </div>
      <div class="fieldset py-0">
        <label for="social-create-home-url" class="label mb-1 font-medium text-base-content/70">
          Home page (optional)
        </label>
        <input
          type="url"
          id="social-create-home-url"
          name={@form[:home_url].name}
          value={@form[:home_url].value}
          placeholder="https://youtube.com/@htc"
          autocomplete="off"
          class={["input w-full", @home_errors != [] && "input-error"]}
          aria-describedby="social-create-home-hint"
          data-role="social-create-home-url"
        />
        <p id="social-create-home-hint" class="mt-1 text-sm text-base-content/70">
          Where clips link back to. Add it later in Settings if you like.
        </p>
        <p
          :for={msg <- @home_errors}
          role="alert"
          class="mt-1.5 flex items-center gap-1.5 text-sm text-base-content"
        >
          <.icon name="hero-exclamation-circle" class="size-4 shrink-0 text-error" />
          {msg}
        </p>
      </div>
      <div class="flex justify-end pt-1">
        <button
          type="submit"
          class="btn btn-primary"
          phx-disable-with="Creating..."
          data-role="social-create-submit"
        >
          Create profile
        </button>
      </div>
    </.form>
    """
  end

  defp field_errors(%Phoenix.HTML.FormField{errors: errors}),
    do: Enum.map(errors, &PlatformWeb.CoreComponents.translate_error/1)

  # A profile with no accounts can do nothing, so its empty queue points at
  # Connections.
  defp empty_queue_copy(profile, true),
    do: "Nothing waiting for approval on #{profile.name}. Connect an account to start."

  defp empty_queue_copy(profile, _), do: "Nothing waiting for approval on #{profile.name}."

  defp tab_labels(counts, profile) do
    [
      {"queue", "Queue (#{count(counts, profile)})"},
      {"calendar", "Calendar"},
      {"connections", "Connections"},
      {"settings", "Settings"}
    ]
  end

  attr :notice, :string, default: nil
  attr :tone, :atom, default: :info, values: [:info, :warning]

  defp notice_line(assigns) do
    ~H"""
    <p
      :if={@notice}
      role="status"
      class={[
        "mb-3 flex items-center justify-between gap-2 px-3 py-2 text-sm",
        @tone == :warning && "alert alert-warning",
        @tone != :warning && "rounded-lg border border-base-300 bg-base-100"
      ]}
      data-role="social-notice"
      data-tone={@tone}
    >
      <span>{@notice}</span>
      <button type="button" class="btn btn-ghost btn-xs" phx-click="dismiss_notice">Dismiss</button>
    </p>
    """
  end

  attr :open?, :boolean, required: true
  attr :form, :any, required: true
  attr :options, :list, required: true

  defp add_account(assigns) do
    ~H"""
    <div class="mb-3" data-role="social-add-account-control">
      <button
        :if={!@open?}
        type="button"
        class="btn btn-sm"
        phx-click="open_add_account"
        data-role="social-add-account"
      >
        <.icon name="hero-plus-micro" class="size-4" /> Add account
      </button>
      <.form
        :if={@open?}
        for={@form}
        id="social-add-account-form"
        phx-submit="add_account"
        class="flex flex-wrap items-end gap-2 rounded-lg border border-base-300 bg-base-200 p-3"
        data-role="social-add-account-form"
      >
        <div class="min-w-40 flex-1">
          <.input
            field={@form[:platform]}
            type="select"
            label="Platform"
            options={@options}
            class="select select-sm w-full"
            data-role="social-add-account-platform"
          />
        </div>
        <div class="flex gap-2">
          <button type="submit" class="btn btn-primary btn-sm" data-role="social-add-account-submit">
            Continue
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="close_add_account"
            data-role="social-add-account-cancel"
          >
            Cancel
          </button>
        </div>
      </.form>
    </div>
    """
  end

  @mode_labels %{"approve_first" => "Approve first", "draft_only" => "Draft-only"}

  attr :account, :map, required: true
  attr :can_edit?, :boolean, required: true
  attr :can_connect?, :boolean, required: true

  defp account_row(assigns) do
    assigns = assign(assigns, :mode_labels, @mode_labels)

    ~H"""
    <span class="flex min-w-0 basis-full items-center gap-3 sm:flex-1 sm:basis-auto">
      <span class="w-20 shrink-0 whitespace-nowrap font-mono text-xs uppercase">
        {@account.platform}
      </span>
      <span class="min-w-0 flex-1 truncate text-sm" data-role="social-account-handle">
        {@account.handle}
      </span>
    </span>
    <%= if @can_edit? do %>
      <form
        id={"social-mode-" <> @account.id}
        phx-change="set_mode"
        class="shrink-0"
        data-role="social-account-mode-form"
      >
        <input type="hidden" name="account_id" value={@account.id} />
        <label class="sr-only" for={"social-mode-select-" <> @account.id}>Approval mode</label>
        <select
          id={"social-mode-select-" <> @account.id}
          name="approval_mode"
          class="select select-sm"
          data-role="social-account-mode"
        >
          <option
            :for={mode <- Account.approval_modes()}
            value={mode}
            selected={mode == @account.approval_mode}
          >
            {@mode_labels[mode]}
          </option>
        </select>
      </form>
    <% else %>
      <span class="badge badge-neutral shrink-0 whitespace-nowrap" data-role="social-account-mode">
        {@mode_labels[@account.approval_mode] || @account.approval_mode}
      </span>
    <% end %>
    <span class="shrink-0" data-role="social-account-state" data-state={@account.status || "none"}>
      <%= case @account.status do %>
        <% "connected" -> %>
          <span class="inline-flex items-center gap-1 text-sm">
            <.icon name="hero-check-circle-micro" class="size-4" /> Connected
          </span>
        <% "reauth_needed" -> %>
          <span class="inline-flex items-center gap-2">
            <span class="badge badge-warning gap-1 whitespace-nowrap">
              <.icon name="hero-exclamation-triangle-micro" class="size-3" /> Reconnect
            </span>
            <button
              :if={@can_connect?}
              type="button"
              class="btn btn-outline btn-sm"
              phx-click="connect_account"
              phx-value-id={@account.id}
              data-role="social-account-connect"
            >
              Reconnect
            </button>
          </span>
        <% _ -> %>
          <button
            :if={@can_connect?}
            type="button"
            class="btn btn-outline btn-sm"
            phx-click="connect_account"
            phx-value-id={@account.id}
            data-role="social-account-connect"
          >
            Connect
          </button>
          <span :if={!@can_connect?} class="text-sm text-base-content/70">Not connected</span>
      <% end %>
    </span>
    <button
      :if={@can_edit?}
      type="button"
      class="btn btn-ghost btn-sm shrink-0 text-base-content/70"
      phx-click="open_remove"
      phx-value-id={@account.id}
      data-role="social-account-remove"
    >
      Remove
    </button>
    """
  end

  attr :account, :map, required: true
  attr :preview, :map, required: true

  # The inline confirm panel under a row (not a modal): the consequence
  # sentence with the real counts, then Cancel (focused on open) and
  # Remove account. Stacked on mobile, Remove account on top.
  defp remove_panel(assigns) do
    assigns = assign(assigns, :segments, removal_segments(assigns.account, assigns.preview))

    ~H"""
    <div
      id={"social-remove-panel-" <> @account.id}
      class="w-full basis-full rounded-lg border border-base-300 border-l-4 border-l-error bg-base-100 p-3 text-sm"
      data-role="social-remove-panel"
    >
      <p data-role="social-remove-sentence">
        <span :for={{class, text} <- @segments} class={class}>{text}</span>
      </p>
      <p :if={@account.status} class="mt-1 text-base-content/70" data-role="social-remove-reconnect">
        You can reconnect this account later.
      </p>
      <div class="mt-3 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
        <button
          id={"social-remove-cancel-" <> @account.id}
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="cancel_remove"
          phx-mounted={JS.focus()}
          data-role="social-remove-cancel"
        >
          Cancel
        </button>
        <button
          type="button"
          class="btn btn-error btn-sm"
          phx-click="remove_account"
          phx-value-id={@account.id}
          phx-disable-with="Removing..."
          data-role="social-remove-confirm"
        >
          Remove account
        </button>
      </div>
    </div>
    """
  end

  # The consequence sentence as {class, text} runs: the label in mono xs,
  # the counts semibold. Only non-zero clauses render.
  defp removal_segments(account, preview) do
    label = {"font-mono text-xs", removal_label(account)}

    if is_nil(account.status) do
      [{nil, "Remove "}, label, {nil, "? It was never connected, so nothing else changes."}]
    else
      [{nil, "Remove "}, label, {nil, "? "}] ++
        removal_clauses(preview.cancelled, preview.shared)
    end
  end

  defp removal_clauses(0, 0), do: [{nil, "No scheduled posts are affected."}]

  defp removal_clauses(cancelled, shared) do
    clauses =
      [
        cancelled > 0 &&
          [
            {"font-semibold", Integer.to_string(cancelled)},
            {nil, " scheduled #{posts(cancelled)} will be cancelled"}
          ],
        shared > 0 &&
          [
            {"font-semibold", Integer.to_string(shared)},
            {nil, " shared #{posts(shared)} will stop posting here"}
          ]
      ]
      |> Enum.filter(& &1)
      |> Enum.intersperse([{nil, ", and "}])
      |> List.flatten()

    clauses ++ [{nil, ". Past posts stay in history."}]
  end

  defp posts(1), do: "post"
  defp posts(_n), do: "posts"

  # The install's Zernio key: a status, never the value. The input is only
  # there while the key is not set, or after Replace / Try again; Save key
  # shows only while the input has text (CSS `peer`, no JS, no phx-change).
  attr :status, :any, required: true
  attr :mode, :atom, required: true
  attr :form, :any, required: true
  attr :nonce, :integer, required: true

  defp zernio_key(assigns) do
    assigns =
      assign(
        assigns,
        :input?,
        assigns.mode == :edit or (assigns.mode == :idle and assigns.status == :not_set)
      )

    ~H"""
    <section
      class="mb-6 max-w-xl rounded-lg border border-base-300 bg-base-100 p-3 sm:p-4"
      aria-labelledby="social-zernio-key-label"
      data-role="social-zernio-key"
      data-state={if @status == :not_set, do: "not_set", else: "set"}
      data-mode={@mode}
    >
      <div class="flex flex-wrap items-center justify-between gap-x-3 gap-y-1">
        <h3 id="social-zernio-key-label" class="text-sm font-semibold text-base-content">
          Zernio API key
        </h3>
        <span
          :if={@status == :not_set}
          class="inline-flex items-center gap-1.5 text-sm font-medium text-warning"
          data-role="social-zernio-status"
        >
          <span class="size-2 rounded-full bg-warning" aria-hidden="true"></span> Not set
        </span>
        <span
          :if={@status != :not_set}
          class="inline-flex items-center gap-1.5 text-sm font-medium text-base-content"
          data-role="social-zernio-status"
        >
          <span class="size-2 rounded-full bg-success" aria-hidden="true"></span> Set
        </span>
      </div>
      <p class="mt-0.5 text-sm text-base-content/70" data-role="social-zernio-scope">
        One key for the whole org. Used by every profile.
      </p>

      <div
        :if={match?({:set, _}, @status) and @mode != :edit}
        class="mt-3 flex flex-wrap items-center justify-between gap-2"
      >
        <p class="text-sm text-base-content/70" data-role="social-zernio-changed">
          {last_changed(@status)}
        </p>
        <button
          :if={@mode == :idle}
          type="button"
          class="btn btn-outline btn-sm"
          phx-click="replace_zernio_key"
          data-role="social-zernio-replace"
        >
          Replace
        </button>
      </div>

      <.form
        :if={@input?}
        for={@form}
        id={"social-zernio-key-form-#{@nonce}"}
        phx-submit="save_zernio_key"
        phx-auto-recover="ignore"
        class="mt-3"
        data-role="social-zernio-key-form"
      >
        <div class="flex flex-wrap items-center gap-2">
          <label for={"social-zernio-key-input-#{@nonce}"} class="sr-only">Zernio API key</label>
          <input
            id={"social-zernio-key-input-#{@nonce}"}
            type="password"
            name={@form[:api_key].name}
            value=""
            placeholder={if @status == :not_set, do: "paste key", else: "paste new key"}
            autocomplete="off"
            autocapitalize="off"
            spellcheck="false"
            class="peer input min-w-0 flex-1 border-edge bg-base-100 font-mono placeholder:text-base-content/70"
            data-role="social-zernio-key-input"
          />
          <button
            type="submit"
            class="btn btn-primary peer-placeholder-shown:hidden"
            data-role="social-zernio-save"
          >
            Save key
          </button>
        </div>
      </.form>
      <p
        :if={@input? and @status == :not_set}
        class="mt-2 text-sm text-base-content/70"
        data-role="social-zernio-helper"
      >
        Find it in Zernio > Settings > API.
      </p>
      <button
        :if={@mode == :edit and @status != :not_set}
        type="button"
        class="btn btn-ghost btn-sm mt-2"
        phx-click="cancel_zernio_key"
        data-role="social-zernio-cancel"
      >
        Cancel
      </button>

      <div
        :if={@mode == :error}
        role="alert"
        class="alert alert-error mt-3 flex flex-wrap items-center justify-between gap-2 text-sm"
        data-role="social-zernio-error"
      >
        <span>Couldn't save the key. Nothing was changed.</span>
        <button
          type="button"
          class="btn btn-sm"
          phx-click="retry_zernio_key"
          data-role="social-zernio-retry"
        >
          Try again
        </button>
      </div>
    </section>
    """
  end

  defp last_changed({:set, %{by: nil, on: on}}), do: "Last changed #{on}"
  defp last_changed({:set, %{by: by, on: on}}), do: "Last changed by #{by}, #{on}"

  attr :profile, :map, required: true
  attr :form, :any, required: true
  attr :can_edit?, :boolean, required: true
  attr :options, :map, required: true

  defp settings(%{can_edit?: false} = assigns) do
    ~H"""
    <dl class="space-y-3 text-sm" data-role="social-settings-readonly">
      <div>
        <dt class="text-base-content/70">Home URL</dt>
        <dd>{@profile.home_url || "Not set"}</dd>
      </div>
      <div>
        <dt class="text-base-content/70">Voice notes</dt>
        <dd class="whitespace-pre-wrap">{@profile.voice_notes || "Not set"}</dd>
      </div>
      <div>
        <dt class="text-base-content/70">Hashtags</dt>
        <dd>{Enum.join(@profile.default_hashtags || [], " ")}</dd>
      </div>
    </dl>
    """
  end

  defp settings(assigns) do
    ~H"""
    <.form
      for={@form}
      id="social-settings-form"
      phx-change="validate_settings"
      phx-submit="save_settings"
      class="max-w-xl space-y-1"
      data-role="social-settings-form"
    >
      <.input field={@form[:home_url]} type="url" label="Home URL" />
      <.input field={@form[:voice_notes]} type="textarea" label="Voice notes" />
      <.input
        field={@form[:default_hashtags]}
        type="text"
        label="Default hashtags (comma-separated)"
      />
      <.input
        field={@form[:approver_user_ids]}
        type="select"
        multiple
        class="w-full select h-auto min-h-24 bg-none py-1"
        size="4"
        label="Approvers (people only)"
        options={Enum.map(@options.approvers, &{&1.name || &1.email, &1.id})}
      />
      <.input
        field={@form[:space_id]}
        type="select"
        label="Approval channel"
        prompt="No channel"
        options={Enum.map(@options.spaces, &{&1.name, &1.id})}
      />
      <button type="submit" class="btn btn-neutral btn-sm mt-2" data-role="social-settings-save">
        Save settings
      </button>
    </.form>
    """
  end

  attr :profile, :map, required: true
  attr :week_start, Date, required: true
  attr :empty?, :boolean, required: true
  attr :rows, :any, required: true
  attr :agenda, :any, required: true

  defp calendar(assigns) do
    assigns = assign(assigns, :days, Cal.days(assigns.week_start))

    ~H"""
    <div class="space-y-4" data-role="social-calendar">
      <div class="flex flex-wrap items-center gap-2" data-role="social-week-nav">
        <button type="button" class="btn btn-ghost btn-sm" phx-click="week_prev" data-role="week-prev">
          <.icon name="hero-chevron-left-micro" class="size-4" /> prev week
        </button>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="week_this" data-role="week-this">
          This week
        </button>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="week_next" data-role="week-next">
          next week <.icon name="hero-chevron-right-micro" class="size-4" />
        </button>
        <span class="text-sm text-base-content/70" data-role="social-week-label">
          Week of {Calendar.strftime(@week_start, "%-d %b %Y")} (UTC)
        </span>
      </div>

      <div class="flex flex-wrap items-center gap-2 text-xs" data-role="social-calendar-legend">
        <.status_mark status="scheduled" />
        <.status_mark status="published" />
        <.status_mark status="failed" />
      </div>

      <p :if={@empty?} class="text-base-content/70" data-role="social-empty">
        Nothing scheduled for {@profile.name} this week.
      </p>

      <%!-- Desktop: one row per account, seven day columns. --%>
      <div class="hidden overflow-x-auto lg:block">
        <div class="grid min-w-[56rem] grid-cols-[11rem_repeat(7,minmax(0,1fr))] gap-px rounded-lg border border-base-300 bg-base-300">
          <div class="bg-base-100 p-2"></div>
          <div
            :for={day <- @days}
            class="bg-base-100 p-2 text-xs font-semibold text-base-content/70"
            data-role="social-day-head"
          >
            {Cal.day_name(day)} {day.day}
          </div>
        </div>
        <div
          id="social-calendar-rows"
          phx-update="stream"
          class="grid min-w-[56rem] grid-cols-[11rem_repeat(7,minmax(0,1fr))] gap-px border-x border-b border-base-300 bg-base-300"
          data-role="social-calendar-rows"
        >
          <div
            :for={{dom_id, row} <- @rows}
            id={dom_id}
            class="contents"
            data-role="social-calendar-row"
          >
            <div class="flex min-w-0 items-center gap-2 bg-base-100 p-2">
              <span class="shrink-0 whitespace-nowrap font-mono text-xs uppercase">
                {row.account.platform}
              </span>
              <span class="min-w-0 truncate text-sm text-base-content/70">{row.account.handle}</span>
            </div>
            <div
              :for={{day, items} <- row.days}
              class="min-h-16 space-y-1 bg-base-200 p-1"
              data-role="social-calendar-cell"
              data-date={Date.to_iso8601(day)}
            >
              <.calendar_item :for={item <- items} item={item} />
            </div>
          </div>
        </div>
      </div>

      <%!-- Mobile: a day-by-day agenda. --%>
      <div
        id="social-agenda"
        phx-update="stream"
        class="space-y-3 lg:hidden"
        data-role="social-agenda"
      >
        <section
          :for={{dom_id, day} <- @agenda}
          id={dom_id}
          class="rounded-lg border border-base-300 bg-base-100"
          data-role="social-agenda-day"
          data-date={day.id}
        >
          <h3 class="border-b border-base-300 bg-base-200 px-3 py-2 text-sm font-semibold">
            {Cal.day_label(day.date)}
          </h3>
          <ul class="divide-y divide-base-300">
            <li :for={item <- day.items}>
              <button
                type="button"
                class="flex w-full min-w-0 items-center gap-2 px-3 py-2 text-left"
                phx-click="open_post"
                phx-value-id={item.post.id}
                data-role="social-calendar-item"
                data-post-id={item.post.id}
              >
                <span class="shrink-0 whitespace-nowrap font-mono text-xs uppercase">
                  {item.account.platform}
                </span>
                <span class="shrink-0 whitespace-nowrap font-mono text-xs">{Cal.time(item.at)}</span>
                <span class="min-w-0 flex-1 truncate text-sm text-base-content/70">
                  {item.account.handle}
                </span>
                <.status_mark status={item.post.status} />
              </button>
            </li>
          </ul>
        </section>
      </div>
    </div>
    """
  end

  attr :item, :map, required: true

  defp calendar_item(assigns) do
    ~H"""
    <button
      type="button"
      class="flex w-full min-w-0 flex-wrap items-center gap-1 rounded bg-base-100 px-1.5 py-1 text-left"
      phx-click="open_post"
      phx-value-id={@item.post.id}
      data-role="social-calendar-item"
      data-post-id={@item.post.id}
    >
      <span class="shrink-0 whitespace-nowrap font-mono text-xs">{Cal.time(@item.at)}</span>
      <.status_mark status={@item.post.status} />
    </button>
    """
  end

  attr :status, :string, required: true

  defp status_mark(assigns) do
    {icon, badge} = Cal.mark(assigns.status)
    assigns = assign(assigns, icon: icon, badge: badge)

    ~H"""
    <span class={["badge badge-sm shrink-0 gap-1 whitespace-nowrap", @badge]} data-status={@status}>
      <.icon name={@icon} class="size-3" />{@status}
    </span>
    """
  end

  attr :detail, :map, required: true

  # Read-only: a side panel at lg, a bottom sheet below (daisy modal).
  defp post_detail(assigns) do
    ~H"""
    <div class="modal modal-open modal-bottom lg:modal-end" data-role="social-post-detail">
      <div class="modal-box border border-base-300 bg-base-100 lg:h-full lg:max-h-none lg:rounded-none">
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0">
            <p class="font-mono text-xs uppercase">{@detail.account.platform}</p>
            <p class="truncate text-sm text-base-content/70">{@detail.account.handle}</p>
          </div>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square"
            phx-click="close_post"
            aria-label="Close"
            data-role="social-post-detail-close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        <div class="mt-3 flex items-center gap-2">
          <span class="font-mono text-xs">
            {Calendar.strftime(@detail.at, "%a %-d %b, %H:%M")} UTC
          </span>
          <.status_mark status={@detail.post.status} />
        </div>
        <p :if={@detail.show_body?} class="mt-3 text-sm" data-role="social-post-detail-body">
          <span class="whitespace-pre-wrap">{@detail.post.body}</span>
        </p>
        <p
          :if={@detail.post.status == "failed" and @detail.post.error}
          class="mt-3 text-sm text-error"
        >
          {@detail.post.error}
        </p>
        <a
          :if={@detail.post.status == "published" and @detail.post.external_url}
          href={@detail.post.external_url}
          target="_blank"
          rel="noopener noreferrer"
          class="link mt-3 inline-block text-sm"
          data-role="social-post-detail-link"
        >
          View published post
        </a>
      </div>
      <button type="button" class="modal-backdrop" phx-click="close_post" aria-label="Close"></button>
    </div>
    """
  end
end
