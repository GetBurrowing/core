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
  is kept and retried, never deleted. Any connect failure names its reason
  (the vendor's status and message, never the URL or key) on the clicked
  row itself as well as in the pane's notice line. `connect_account` also runs
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
  `provider_profile_ref`, while at least one never-connected row is listed,
  or while a connected row has a nil `platform_account_type` (task 01a1653a)
  and this LiveView has not asked yet: that type check runs at most ONCE per
  LiveView process, so an Instagram row Zernio never types costs one list
  call per page session, not one per tab click. The same call backfills the
  type on connected rows when Zernio reports one (no notice, no copy change).
  `Platform.Social.reconcile_accounts/3` re-checks the approver and the ref
  and sends nothing when no row is pending and no connected row lacks a
  type. Picked-up rows show Connected
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

  ## Employee accounts: owner line, invites, landing page (task 01a14ce1)

  An owned account's row carries `Owner: <name>`; unowned rows carry
  nothing. An approver gets "Invite someone to connect" (secondary, next
  to Add account), a dialog (bottom sheet below sm) that calls
  `Platform.Social.create_invite/5` and shows the link ONCE, and the
  pending invites with Cancel (`cancel_invite/3`). Only the token's hash
  is stored, so a pending row cannot re-show its link.

  `?invite=<token>` renders the invitee landing page INSTEAD of the
  profile UI, for every state (ready, expired, used, cancelled, not valid,
  signed out). Continue calls `Platform.Social.start_invite_connect/3`
  for the viewer, re-read on the click; the vendor return
  (`?invite_connect=<nonce>`) lands on the success card, or on the failed
  card whose Try again calls `restart_invite_connect/3`. The token (or
  nonce) is kept in assigns only while it can still be used, as a lookup
  key: every event re-resolves it through Social.
  """
  use PlatformWeb, :live_view

  alias Phoenix.LiveView.JS
  alias PlatformWeb.SocialProjectSetting

  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Social
  alias Platform.Accounts.User
  alias Platform.Social.{Account, Approvals, Publisher, Secrets}
  alias PlatformWeb.SocialCalendar, as: Cal

  @tabs ~w(queue calendar clips connections settings)

  # Clip Studio 3/9: the Clips tab's two views (`?view=`).
  @clips_views ~w(review library)

  # The queue's status filter chips (task 01a165f1), in display order.
  @queue_filters ~w(needs_approval not_published)

  @approver_refusals [
    :not_an_approver,
    :not_a_human,
    :approver_archived,
    :approver_no_access,
    :not_the_owner
  ]

  @invite_unusable "That invite link can't finish this connection. Nothing changed. Ask for a new link."

  # An uploaded cover's size cap (task 01a165ec stage 4).
  @cover_max_bytes 15_000_000

  # The invite dialog's expiry choices, in days; 7 is the default.
  @invite_ttl_days [1, 3, 7, 14]

  @impl true
  def mount(_params, session, socket) do
    user = Platform.Accounts.get_user(session["user_id"])
    profiles = if user, do: Social.list_profiles_for_user(user), else: []

    socket =
      socket
      |> assign(:user, user)
      |> assign(:tab, "queue")
      |> assign(:queue_canvas_ids, [])
      |> assign(:queue_filter, nil)
      |> assign(:type_checked_profile_ids, MapSet.new())
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
      |> assign(:invite_dialog, nil)
      |> assign(:landing, nil)
      |> assign(:invite_token, nil)
      |> assign(:invite_nonce, nil)
      |> assign(:cover_picker, nil)
      |> assign(:clips_view, "review")
      |> assign(:clips_clip_id, nil)
      |> assign(:clips_profile_id, nil)
      |> assign(:clips_count, 0)
      |> allow_upload(:cover,
        accept: ~w(.jpg .jpeg .png),
        max_entries: 1,
        max_file_size: @cover_max_bytes,
        auto_upload: true,
        progress: &handle_cover_progress/3
      )

    socket = load_profile(socket, List.first(profiles))
    query = session["query"]

    socket =
      case landing_params(query) do
        # The invitee landing page (task 01a14ce1, stage 4): rendered
        # INSTEAD of the profile UI. Resolving the invite reads only, so it
        # runs on the static render too.
        {:invite, token} ->
          assign_invite_landing(socket, token, user)

        # A cancelled or failed vendor connect started from an invite.
        {:invite_failed, nonce} ->
          if connected?(socket),
            do: assign_failed_landing(socket, nonce, user),
            else: assign(socket, :landing, %{state: :checking})

        :none ->
          # The OAuth return: connected mount only (the static render sends
          # no vendor request, so the vendor is asked once), live humans only.
          cond do
            connected?(socket) and human?(user) ->
              socket
              |> handle_return(profiles, return_params(query))
              |> select_from_query(profiles, query)

            is_map(query) and is_map_key(query, "invite_connect") and human?(user) ->
              assign(socket, :landing, %{state: :checking})

            true ->
              select_from_query(socket, profiles, query)
          end
      end

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

  # Task 01a165f1: the queue's status filter. Pressing the active chip
  # clears it; the stream is re-read and re-streamed with `reset: true`.
  def handle_event("queue_filter", %{"filter" => filter}, socket)
      when filter in @queue_filters do
    filter = if socket.assigns.queue_filter == filter, do: nil, else: filter
    {:noreply, socket |> assign(:queue_filter, filter) |> load_queue()}
  end

  def handle_event("queue_filter", _params, socket), do: {:noreply, socket}

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
         %Account{} = account <- profile_account(profile, id) do
      with publisher when is_atom(publisher) <- Publisher.impl(),
           {:ok, profile} <- Social.ensure_provider_profile(profile.org_id, profile),
           {:ok, url} <-
             publisher.connect_url(account, redirect_url: own_url("/m/social"), profile: profile) do
        {:noreply, redirect(socket, external: url)}
      else
        error -> {:noreply, connect_failed(socket, account, error)}
      end
    else
      {:error, :not_an_approver} ->
        {:noreply, notice(socket, "Only an approver of this profile can change it.")}

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
        error -> {:noreply, connect_failed(socket, account, error)}
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

  # Project for renders (task 01a16532): saves on choose. The approver is
  # re-checked here and in Social.set_profile_project/4; the id must be one
  # of the options rebuilt now (SocialProjectSetting.save/3).
  def handle_event("set_profile_project", params, socket) do
    with {:ok, profile, user_id} <- authorize(socket),
         {:ok, profile} <- SocialProjectSetting.save(profile, user_id, params["project_id"]) do
      Process.send_after(self(), :project_saved_clear, SocialProjectSetting.saved_ms())

      {:noreply,
       socket
       |> assign(:profile, profile)
       |> assign(:project_setting, %{SocialProjectSetting.load(profile, true) | saved?: true})}
    else
      {:error, :not_an_approver} ->
        {:noreply, notice(socket, "Only an approver of this profile can change it.")}

      _ ->
        {:noreply, notice(socket, "Those settings could not be saved.")}
    end
  end

  def handle_event("dismiss_notice", _params, socket),
    do: {:noreply, assign(socket, :notice, nil)}

  # ── Invites, approver side (task 01a14ce1, stage 4) ──────────────────
  # Every handler re-checks the approver through authorize/1 (and
  # Social.create_invite/5 / cancel_invite/3 re-check again inside). The
  # raw token lives only in the created dialog's URL, dropped on close.

  def handle_event("open_invite", _params, socket) do
    case authorize(socket) do
      {:ok, _profile, _user_id} ->
        {:noreply,
         assign(socket, :invite_dialog, %{
           step: :form,
           form: invite_form(socket.assigns.connectable_platforms)
         })}

      _ ->
        {:noreply, assign(socket, :invite_dialog, nil)}
    end
  end

  def handle_event("close_invite", _params, socket),
    do: {:noreply, assign(socket, :invite_dialog, nil)}

  def handle_event("create_invite", %{"invite" => %{"platform" => platform} = params}, socket)
      when is_binary(platform) do
    with {:ok, days} <- invite_days(params["ttl_days"]),
         {:ok, profile, user_id} <- authorize(socket),
         {:ok, invite, token} <-
           Social.create_invite(profile.org_id, profile, user_id, platform, days) do
      {:noreply,
       socket
       |> assign(:invite_dialog, %{
         step: :created,
         url: own_url("/m/social?" <> URI.encode_query(%{"invite" => token})),
         expires_on: short_date(invite.expires_at)
       })
       |> restream_invites()}
    else
      {:error, reason} when reason in @approver_refusals ->
        {:noreply,
         socket
         |> assign(:invite_dialog, nil)
         |> notice("Only an approver of this profile can change it.")}

      _ ->
        {:noreply,
         socket
         |> assign(:invite_dialog, nil)
         |> notice("That invite link could not be created. Try again.")}
    end
  end

  def handle_event("create_invite", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_invite", %{"id" => id}, socket) when is_binary(id) do
    with {:ok, profile, user_id} <- authorize(socket),
         {:ok, _invite} <- Social.cancel_invite(profile.org_id, id, user_id) do
      {:noreply, socket |> restream_invites() |> notice("Invite cancelled.")}
    else
      {:error, :used} ->
        {:noreply, socket |> restream_invites() |> notice("That invite was already used.")}

      {:error, reason} when reason in @approver_refusals ->
        {:noreply, notice(socket, "Only an approver of this profile can change it.")}

      _ ->
        {:noreply, socket |> restream_invites() |> notice("That invite is already gone.")}
    end
  end

  def handle_event("cancel_invite", _params, socket), do: {:noreply, socket}

  # ── Invites, invitee side (task 01a14ce1, stage 4) ───────────────────
  # The user is re-read and the invite re-resolved through Social on every
  # event; the token or nonce in assigns is only a lookup key, never proof.

  def handle_event("invite_continue", _params, socket) do
    user = fresh_user(socket)

    case {user, socket.assigns.invite_token} do
      {%User{archived_at: nil} = user, token} when is_binary(token) ->
        case Social.start_invite_connect(token, user.id) do
          {:ok, url} ->
            {:noreply, redirect(socket, external: url)}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign_invite_landing(token, user)
             |> landing_error("Couldn't start the LinkedIn connection. Try again.")}
        end

      # No usable invite on this page (expired, used, forged...): nothing
      # to start, and no request.
      {_user, nil} ->
        {:noreply, socket}

      {_user, token} ->
        {:noreply, assign_invite_landing(socket, token, user)}
    end
  end

  def handle_event("invite_retry", _params, socket) do
    user = fresh_user(socket)

    case {user, socket.assigns.invite_nonce} do
      {%User{archived_at: nil} = user, nonce} when is_binary(nonce) ->
        case Social.restart_invite_connect(nonce, user.id) do
          {:ok, url} ->
            {:noreply, redirect(socket, external: url)}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign_failed_landing(nonce, user)
             |> landing_error(
               "Couldn't start the LinkedIn connection. Open your invite link again."
             )}
        end

      {_user, nil} ->
        {:noreply, socket}

      {_user, nonce} ->
        {:noreply, assign_failed_landing(socket, nonce, user)}
    end
  end

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

  # ── Cover picker (task 01a165ec stage 4) ─────────────────────────────
  #
  # A video post's cover, from the queue card's Cover control. Every write
  # goes through `Social.set_cover/4` (the approver and the one cover rule
  # are checked there, on a fresh read); the picker only stages. The frame
  # tab's `cover_frame` comes from the CoverPicker hook (integer ms); the
  # upload tab stores the image as a file of the profile's project as soon
  # as it arrives, and "Use this cover" applies it.

  def handle_event("cover_open", %{"post-id" => post_id}, socket) when is_binary(post_id),
    do: {:noreply, open_cover_picker(socket, post_id)}

  def handle_event("cover_open", _params, socket), do: {:noreply, socket}

  def handle_event("cover_close", _params, socket), do: {:noreply, close_cover_picker(socket)}

  def handle_event("cover_tab", %{"tab" => tab}, socket) when tab in ~w(frame upload),
    do: {:noreply, update_cover_picker(socket, &%{&1 | tab: tab, error: nil})}

  def handle_event("cover_tab", _params, socket), do: {:noreply, socket}

  def handle_event("cover_frame", %{"post_id" => post_id, "offset_ms" => ms} = params, socket)
      when is_binary(post_id) and is_integer(ms) do
    attrs =
      case params["duration_ms"] do
        d when is_integer(d) and d > 0 -> %{cover_offset_ms: ms, duration_ms: d}
        _ -> %{cover_offset_ms: ms}
      end

    {:noreply, apply_cover(socket, post_id, attrs)}
  end

  def handle_event("cover_frame", _params, socket), do: {:noreply, socket}

  def handle_event("cover_reset", _params, socket) do
    case socket.assigns.cover_picker do
      %{post_id: post_id} -> {:noreply, apply_cover(socket, post_id, :clear)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cover_upload_validate", _params, socket),
    do: {:noreply, update_cover_picker(socket, &%{&1 | error: nil})}

  def handle_event("cover_upload_save", _params, socket) do
    case socket.assigns.cover_picker do
      %{post_id: post_id, staged: %{file_id: file_id}} ->
        {:noreply, apply_cover(socket, post_id, %{cover_file_id: file_id})}

      _ ->
        {:noreply, socket}
    end
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

  def handle_info(:project_saved_clear, %{assigns: %{project_setting: %{} = s}} = socket),
    do: {:noreply, assign(socket, :project_setting, %{s | saved?: false})}

  # Clip Studio 3/9: a clips-topic broadcast for the CURRENT profile goes
  # to the Review bay and refreshes the tab's count; any other is ignored.
  def handle_info({:social_clip, %Platform.Social.Clip{} = clip}, socket) do
    case socket.assigns.profile do
      %{id: profile_id} when profile_id == clip.profile_id ->
        send_update(PlatformWeb.SocialClipsReview, id: "social-clips-review", clip_event: clip)
        {:noreply, load_clips_count(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  # The Review bay's segmented control.
  def handle_info({:clips_view, view}, socket) when view in @clips_views,
    do: {:noreply, assign(socket, :clips_view, view)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # ONE place a profile becomes current. Every per-profile stream loads here
  # with `reset: true`, so a switch leaves nothing of the previous profile.
  defp load_profile(socket, profile) do
    socket
    |> assign(:profile, profile)
    |> assign(:detail, nil)
    |> load_queue()
    |> assign(:notice, nil)
    |> load_calendar()
    |> load_connections()
    |> maybe_reconcile()
    |> load_clips()
  end

  # Clip Studio 3/9: the current profile's clips topic (the previous
  # profile's is dropped) and the Clips tab's pending count.
  defp load_clips(socket) do
    previous = socket.assigns.clips_profile_id
    current = socket.assigns.profile && socket.assigns.profile.id

    if connected?(socket) and previous != current do
      if previous, do: Phoenix.PubSub.unsubscribe(Platform.PubSub, Social.clips_topic(previous))
      if current, do: Phoenix.PubSub.subscribe(Platform.PubSub, Social.clips_topic(current))
    end

    socket
    |> assign(:clips_profile_id, if(connected?(socket), do: current))
    |> load_clips_count()
  end

  defp load_clips_count(%{assigns: %{profile: %{id: id, org_id: org_id}}} = socket),
    do: assign(socket, :clips_count, Platform.Social.ClipReviewFeed.pending_count(org_id, id))

  defp load_clips_count(socket), do: assign(socket, :clips_count, 0)

  # The queue stream for the current profile and filter, with `reset: true`.
  # `queue_refused?` (any refused post, whatever the filter) shows the chips.
  defp load_queue(socket) do
    all = queue_rows(socket.assigns.profile)
    rows = filter_queue(all, socket.assigns.queue_filter)
    canvas_ids = for %{card: %{canvas_id: id}} <- rows, do: id

    if connected?(socket) do
      Enum.each(socket.assigns.queue_canvas_ids -- canvas_ids, &ChatPubSub.unsubscribe_canvas/1)
      Enum.each(canvas_ids -- socket.assigns.queue_canvas_ids, &ChatPubSub.subscribe_canvas/1)
    end

    socket
    |> assign(:queue_canvas_ids, canvas_ids)
    |> assign(:queue_cards, Map.new(for %{card: %{} = c} <- rows, do: {c.canvas_id, c.id}))
    |> assign(:queue_empty?, rows == [])
    |> assign(:queue_refused?, Enum.any?(all, & &1.refused?))
    |> stream(:queue, rows, reset: true)
  end

  defp filter_queue(rows, "needs_approval"), do: Enum.reject(rows, & &1.refused?)
  defp filter_queue(rows, "not_published"), do: Enum.filter(rows, & &1.refused?)
  defp filter_queue(rows, _none), do: rows

  # Connections and Settings for the current profile. `can_edit?` is ONLY
  # for rendering; every write handler re-checks through `authorize/1`.
  defp load_connections(%{assigns: %{profile: nil}} = socket) do
    socket
    |> assign(:removing, nil)
    |> assign(:can_edit?, false)
    |> assign(:accounts_empty?, true)
    |> assign(:pending_accounts?, false)
    |> assign(:untyped_accounts?, false)
    |> assign(:connectable_platforms, [])
    |> assign(:add_open?, false)
    |> assign(:add_form, add_form([]))
    |> assign(:settings_options, %{approvers: [], spaces: []})
    |> assign(:project_setting, nil)
    |> assign(:settings_form, nil)
    |> assign(:invite_dialog, nil)
    |> assign(:invites_empty?, true)
    |> stream(:accounts, [], reset: true)
    |> stream(:invites, [], reset: true)
  end

  defp load_connections(%{assigns: %{profile: profile}} = socket) do
    accounts = Social.list_accounts(profile.org_id, profile_id: profile.id)
    can_edit? = match?({:ok, _, _}, authorize(socket))

    platforms = Social.connectable_platforms()

    socket
    |> assign(:removing, nil)
    |> assign(:can_edit?, can_edit?)
    |> assign(:accounts_empty?, accounts == [])
    |> assign_reconcile_flags(accounts)
    |> assign(:connectable_platforms, platforms)
    |> assign(:add_open?, false)
    |> assign(:add_form, add_form(platforms))
    |> assign(:settings_options, settings_options(profile, can_edit?))
    |> assign(:project_setting, SocialProjectSetting.load(profile, can_edit?))
    |> assign(:settings_form, settings_form(profile, %{}))
    |> assign(:invite_dialog, nil)
    |> stream(:accounts, Enum.map(accounts, &account_item(&1, nil)), reset: true)
    |> restream_invites()
  end

  # Pending invites (unused, uncancelled, unexpired) for an APPROVER of the
  # current profile only; anyone else gets an empty list. Used and expired
  # invites drop off because list_pending_invites/2 never returns them.
  defp restream_invites(%{assigns: %{profile: %{}}} = socket) do
    invites =
      case authorize(socket) do
        {:ok, fresh, _user_id} -> Social.list_pending_invites(fresh.org_id, fresh)
        _ -> []
      end

    socket
    |> assign(:invites_empty?, invites == [])
    |> stream(:invites, Enum.map(invites, &invite_item/1), reset: true)
  end

  defp restream_invites(socket), do: socket

  # Only display fields: never the token (it is not stored) or its hash.
  defp invite_item(invite) do
    %{
      id: invite.id,
      platform: invite.platform,
      expires_on: short_date(invite.expires_at),
      expiring?: DateTime.diff(invite.expires_at, DateTime.utc_now()) < 86_400
    }
  end

  # A stream row; `removal` is the open confirm panel's preview, else nil.
  defp account_item(account, removing, connect_error \\ nil)

  defp account_item(account, %{account_id: id, preview: preview}, connect_error)
       when id == account.id,
       do: %{
         id: account.id,
         account: account,
         removal: preview,
         owner: owner_of(account),
         connect_error: connect_error
       }

  defp account_item(account, _removing, connect_error),
    do: %{
      id: account.id,
      account: account,
      removal: nil,
      owner: owner_of(account),
      connect_error: connect_error
    }

  # Connect (or the connect step of Add account) failed: the reason goes on
  # the row that was clicked AND in the pane's notice line, because the
  # notice sits at the top of Connections and is off-screen under a long
  # list or on a phone (2026-10-21: "nothing happens"). The rows are re-read
  # so an account that Add just created shows with Connect.
  defp connect_failed(socket, %Account{} = account, error) do
    text = connect_error_copy(account, error)

    socket
    |> restream_accounts(%{account.id => text})
    |> notice(text, :warning)
  end

  @platform_labels %{
    "x" => "X",
    "linkedin" => "LinkedIn",
    "tiktok" => "TikTok",
    "instagram" => "Instagram",
    "youtube" => "YouTube"
  }

  defp connect_error_copy(%Account{platform: platform}, error) do
    "Couldn't connect #{Map.get(@platform_labels, platform, platform)}. " <>
      connect_reason(error)
  end

  # Strings come from the publisher's response handling (status code plus
  # the vendor's own message, never the URL or the key).
  defp connect_reason({:error, reason}) when is_binary(reason), do: reason

  defp connect_reason({:error, :publisher_not_configured}),
    do: "Publishing isn't configured on this install."

  defp connect_reason({:error, :credentials_unavailable}),
    do: "Add the Zernio API key in Settings first."

  defp connect_reason({:error, :credentials_rejected}),
    do: "Zernio rejected the API key (HTTP 401). Check the key in Settings."

  defp connect_reason({:error, :rate_limited}),
    do: "Zernio is rate limiting requests (HTTP 429). Try again in a minute."

  defp connect_reason({:error, :not_found}),
    do: "Zernio couldn't find this profile (HTTP 404). Try again."

  defp connect_reason({:error, :unexpected_response}),
    do: "Zernio answered without a sign-in link. Try again."

  defp connect_reason({:error, :profile_not_linked}),
    do: "This profile isn't linked to Zernio yet. Try again."

  defp connect_reason({:error, {:unsupported_platform, _}}),
    do: "That platform can't be connected on this install."

  defp connect_reason({:error, {:profile_name_taken, _} = reason}), do: add_error_copy(reason)
  defp connect_reason(_), do: "Try again."

  # The owner line (task 01a14ce1, stage 4): only an owned account carries
  # one. Display fields only.
  defp owner_of(%Account{owner_user_id: id}) when is_binary(id) do
    case Platform.Accounts.get_user(id) do
      %User{} = user -> %{name: user_name(user), avatar_url: user.avatar_url}
      nil -> nil
    end
  end

  defp owner_of(_account), do: nil

  defp user_name(%User{name: name}) when is_binary(name) and name != "", do: name
  defp user_name(%User{email: email}) when is_binary(email), do: email
  defp user_name(_user), do: "someone"

  defp initial(name) when is_binary(name) and name != "",
    do: name |> String.first() |> String.upcase()

  defp initial(_name), do: "?"

  # "Oct 24"
  defp short_date(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d")

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
    |> assign_reconcile_flags(accounts)
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

  # `errors` maps an account id to the connect failure shown on its row.
  defp restream_accounts(socket, errors \\ %{})

  defp restream_accounts(%{assigns: %{profile: nil}} = socket, _errors), do: socket

  defp restream_accounts(%{assigns: %{profile: profile}} = socket, errors) do
    accounts = Social.list_accounts(profile.org_id, profile_id: profile.id)
    removing = socket.assigns.removing

    socket
    |> assign(:accounts_empty?, accounts == [])
    |> assign_reconcile_flags(accounts)
    |> stream(
      :accounts,
      Enum.map(accounts, &account_item(&1, removing, Map.get(errors, &1.id))),
      reset: true
    )
  end

  # The rows `Platform.Social.reconcile_accounts/3` can fill: never connected
  # (no status, no vendor ref). Mirrors the context's own predicate.
  defp never_connected?(%Account{status: nil, provider_account_ref: nil, archived_at: nil}),
    do: true

  defp never_connected?(_account), do: false

  # Connected rows whose vendor account type we have never learned (task
  # 01a1653a): `reconcile_accounts/3` backfills them. Mirrors the context's
  # own predicate.
  defp untyped_connected?(%Account{
         status: "connected",
         provider_account_ref: ref,
         archived_at: nil,
         platform_account_type: nil
       })
       when is_binary(ref),
       do: true

  defp untyped_connected?(_account), do: false

  defp assign_reconcile_flags(socket, accounts) do
    socket
    |> assign(:pending_accounts?, Enum.any?(accounts, &never_connected?/1))
    |> assign(:untyped_accounts?, Enum.any?(accounts, &untyped_connected?/1))
  end

  # ── Reconcile on opening Connections (task 01a14807) ────────────────

  # Picks up accounts connected at the vendor whose return never reached us,
  # and backfills the account type on connected rows that have none.
  # Runs only on the Connections tab, on a connected socket, for a viewer who
  # passes `authorize/1`, on a profile with a vendor ref, while a
  # never-connected row is listed, or while a connected row has a nil
  # `platform_account_type` and this LiveView has not yet asked for THIS
  # profile (an Instagram row Zernio can never type costs one list call per
  # profile per page session, not one per tab click; switching to another
  # profile asks once for that profile too). `reconcile_accounts/3` re-checks the approver and the ref
  # and sends nothing when there is nothing to do, so once every row is
  # connected and typed this costs zero requests. Synchronous: the
  # publisher's 5s receive_timeout bounds how long the click can block.
  defp maybe_reconcile(%{assigns: %{tab: "connections"} = assigns} = socket) do
    if reconcile_due?(assigns), do: reconcile(socket), else: socket
  end

  defp maybe_reconcile(socket), do: socket

  defp reconcile_due?(%{pending_accounts?: true}), do: true

  defp reconcile_due?(%{untyped_accounts?: true, profile: %{id: id}} = assigns),
    do: not MapSet.member?(assigns.type_checked_profile_ids, id)

  defp reconcile_due?(_assigns), do: false

  defp reconcile(socket) do
    with true <- connected?(socket),
         {:ok, fresh, user_id} <- authorize(socket),
         ref when is_binary(ref) and ref != "" <- fresh.provider_profile_ref do
      socket
      |> update(:type_checked_profile_ids, &MapSet.put(&1, fresh.id))
      |> reconciled(Social.reconcile_accounts(fresh.org_id, fresh, user_id))
    else
      _ -> socket
    end
  end

  defp reconciled(socket, {:ok, %{connected: [_ | _] = accounts}}) do
    n = length(accounts)
    noun = if n == 1, do: "account", else: "accounts"
    names = Enum.map_join(accounts, ", ", &account_label/1)

    socket
    |> restream_accounts()
    |> notice("Picked up #{n} connected #{noun} from Zernio: #{names}.")
  end

  # A backfilled type changes no copy; restream so the flags are current.
  defp reconciled(socket, {:ok, %{typed: [_ | _]}}), do: restream_accounts(socket)

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

  # ── Invite dialog ───────────────────────────────────────────────────

  defp invite_form(platforms),
    do: to_form(%{"platform" => List.first(platforms), "ttl_days" => "7"}, as: :invite)

  defp invite_days(value) when is_binary(value) do
    case Integer.parse(value) do
      {days, ""} when days in @invite_ttl_days -> {:ok, days}
      _ -> {:error, :invalid_ttl}
    end
  end

  defp invite_days(_value), do: {:error, :invalid_ttl}

  defp ttl_options, do: Enum.map(@invite_ttl_days, &{ttl_label(&1), Integer.to_string(&1)})

  defp ttl_label(1), do: "1 day"
  defp ttl_label(days), do: "#{days} days"

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
  @nonce ~r/\A[A-Za-z0-9_-]{16,128}\z/

  # The ONE parser for the host's forwarded query (untrusted strings).
  # Only profileId, accountId and error are read; username, error_message
  # and every other key are ignored (the handle comes from the vendor list).
  defp return_params(%{"error" => error} = query) when is_binary(error) do
    {:return_error, %{code: shaped(error, @error_code), profile_ref: shaped(query["profileId"])}}
  end

  # An invite return (task 01a14ce1): the per-connect nonce plus the
  # vendor's ids. Authorized by the invite, not by authorize/1.
  defp return_params(%{"invite_connect" => nonce} = query) do
    case {shaped(nonce, @nonce), shaped(query["profileId"]), shaped(query["accountId"])} do
      {nonce, profile_ref, account_ref}
      when is_binary(nonce) and is_binary(profile_ref) and is_binary(account_ref) ->
        {:return_invite, %{nonce: nonce, profile_ref: profile_ref, account_ref: account_ref}}

      _ ->
        :return_malformed
    end
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
            Social.complete_connect(fresh.org_id, fresh, {:approver, user_id}, %{
              account_ref: params.account_ref
            })
          end

        socket |> restream_accounts() |> notice(return_copy(result, profile))
    end
  end

  # The invite return goes through the SAME Social.complete_connect/4, with
  # the invite as the authorization: the invitee need not be an approver.
  # It lands on the invitee landing page (task 01a14ce1, stage 4): success,
  # a refused invite, or a vendor-side failure with Try again.
  defp handle_return(socket, profiles, {:return_invite, params}) do
    case return_profile(profiles, params.profile_ref) do
      nil ->
        assign(socket, :landing, %{state: :invalid, message: @invite_unusable})

      profile ->
        user = socket.assigns.user

        result =
          Social.complete_connect(
            profile.org_id,
            profile,
            {:invite, params.nonce, user.id},
            %{account_ref: params.account_ref}
          )

        case result do
          {:ok, account, _outcome} ->
            assign(socket, :landing, %{
              state: :success,
              brand: profile.name,
              platform: platform_label(account.platform),
              dm_path: owner_dm_path(profile, user)
            })

          {:error, reason}
          when reason in [:not_found, :expired, :used, :cancelled, :not_the_inviter] or
                 reason in @approver_refusals ->
            assign(socket, :landing, %{state: :invalid, message: @invite_unusable})

          {:error, _vendor_or_listing} ->
            assign_failed_landing(socket, params.nonce, user)
        end
    end
  end

  # ── Invitee landing page (task 01a14ce1, stage 4) ────────────────────

  # ?invite=<token> is the shared link; ?invite_connect=<nonce>&error=... is
  # a cancelled or failed vendor leg. Everything else is the normal page.
  defp landing_params(%{"invite" => token}) when is_binary(token), do: {:invite, token}

  defp landing_params(%{"invite_connect" => nonce, "error" => _}) when is_binary(nonce),
    do: {:invite_failed, nonce}

  defp landing_params(_query), do: :none

  # Resolves the shared token for the viewer, re-read now. The token is
  # kept in assigns ONLY while the invite is usable (Continue needs it as a
  # lookup key); every other state drops it.
  defp assign_invite_landing(socket, token, user) do
    shaped_token = shaped(token, @nonce)

    result =
      cond do
        not human?(user) -> :signed_out
        is_nil(shaped_token) -> {:error, :not_found}
        true -> Social.invite_landing_for(shaped_token, user.id)
      end

    case result do
      :signed_out ->
        socket |> assign(:invite_token, nil) |> assign(:landing, %{state: :signed_out})

      {:ok, invite, profile} ->
        socket
        |> assign(:invite_token, shaped_token)
        |> assign(:landing, landing(:ready, invite, profile, user))

      {:error, state, invite, profile} ->
        socket
        |> assign(:invite_token, nil)
        |> assign(:landing, landing(state, invite, profile, user))

      {:error, _reason} ->
        socket
        |> assign(:invite_token, nil)
        |> assign(:landing, %{state: :invalid, message: "This invite link isn't valid."})
    end
  end

  # The vendor leg was cancelled or failed. The nonce stays in assigns only
  # while Try again can use it.
  defp assign_failed_landing(socket, nonce, user) do
    shaped_nonce = shaped(nonce, @nonce)

    result =
      cond do
        not human?(user) -> :signed_out
        is_nil(shaped_nonce) -> {:error, :not_found}
        true -> Social.invite_return_for(shaped_nonce, user.id)
      end

    case result do
      :signed_out ->
        socket |> assign(:invite_nonce, nil) |> assign(:landing, %{state: :signed_out})

      {:ok, invite, profile} ->
        socket
        |> assign(:invite_nonce, shaped_nonce)
        |> assign(:landing, landing(:failed, invite, profile, user))

      {:error, state, invite, profile} ->
        socket
        |> assign(:invite_nonce, nil)
        |> assign(:landing, landing(state, invite, profile, user))

      {:error, _reason} ->
        socket
        |> assign(:invite_nonce, nil)
        |> assign(:landing, %{state: :invalid, message: @invite_unusable})
    end
  end

  defp landing(state, invite, profile, user) do
    %{
      state: state,
      brand: profile.name,
      platform: platform_label(invite.platform),
      inviter: inviter_name(invite.created_by_user_id),
      expires_on: short_date(invite.expires_at),
      viewer_used?: state == :used and invite.used_by_user_id == user.id,
      profile_id: profile.id,
      error: nil
    }
  end

  defp landing_error(%{assigns: %{landing: %{state: state} = landing}} = socket, text)
       when state in [:ready, :failed],
       do: assign(socket, :landing, Map.put(landing, :error, text))

  defp landing_error(socket, _text), do: socket

  defp inviter_name(user_id) when is_binary(user_id) do
    case Platform.Accounts.get_user(user_id) do
      %User{} = user -> user_name(user)
      nil -> "the person who invited you"
    end
  end

  defp inviter_name(_user_id), do: "the person who invited you"

  # The owner's ONE Social DM, where drafts for their own account arrive
  # (Approvals.owner_dm/2, find-or-create). No link when it can't be had.
  defp owner_dm_path(profile, %User{id: user_id}) do
    case Approvals.owner_dm(profile.org_id, user_id) do
      {:ok, space} -> "/chat/" <> Platform.Chat.space_path_segment(space)
      _ -> nil
    end
  end

  # ?tab=connections&profile=<id> (the landing page's link back to a used
  # invite's account): a tab in @tabs and a profile among the VISIBLE ones,
  # else ignored.
  defp select_from_query(socket, profiles, %{} = query) do
    socket =
      case Enum.find(profiles, &(&1.id == query["profile"])) do
        nil -> socket
        profile -> load_profile(socket, profile)
      end

    socket =
      socket
      |> assign(:clips_view, if(query["view"] in @clips_views, do: query["view"], else: "review"))
      |> assign(:clips_clip_id, clips_clip_param(query["clip"]))

    case query["tab"] do
      tab when tab in @tabs -> socket |> assign(:tab, tab) |> maybe_reconcile()
      _ -> socket
    end
  end

  defp select_from_query(socket, _profiles, _query), do: socket

  defp clips_clip_param(clip) when is_binary(clip) do
    case Ecto.UUID.cast(clip) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp clips_clip_param(_clip), do: nil

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
          Social.post_approver_check(profile.org_id, profile, account, user_id) == :ok

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

  #
  # Task 01a165f1: then its approved posts whose publish was refused before
  # the vendor (`refused: true`), each with its newest (decided) card.
  defp queue_rows(profile) do
    pending =
      profile.org_id
      |> Social.list_posts(profile_id: profile.id, status: "needs_approval")
      |> Enum.map(&queue_row(&1, Approvals.live_card(&1.id), false))

    refused =
      profile.org_id
      |> Social.list_posts(profile_id: profile.id, refused: true)
      |> Enum.map(&queue_row(&1, Approvals.latest_card(&1.id), true))

    pending ++ refused
  end

  defp queue_row(post, card, refused?),
    do: %{id: post.id, post: post, card: card, rev: card && card_rev(card), refused?: refused?}

  defp card_rev(card) do
    case Platform.Chat.get_canvas(card.canvas_id) do
      %{document: document} -> rev_of(document)
      _ -> nil
    end
  end

  defp rev_of(%{"root" => %{"props" => %{"rev" => rev}}}) when is_integer(rev), do: rev
  defp rev_of(_), do: nil

  # ── Cover picker helpers (task 01a165ec stage 4) ─────────────────────

  # The picker opens only on a video post of the CURRENT profile that this
  # viewer may change; anything else is a no-op (the card shows no button).
  defp open_cover_picker(socket, post_id) do
    with {:ok, profile, user_id} <- authorize(socket),
         %Social.Post{} = post <- Social.get_post(profile.org_id, post_id),
         %Account{} = account <- profile_account(profile, post.account_id),
         %{} = card <- Approvals.live_card(post.id),
         %{cover: %{editable?: true} = cover, role: :approver} <-
           Approvals.card_view(card.id, {:user, user_id}) do
      socket
      |> cancel_cover_uploads()
      |> assign(:cover_picker, %{
        post_id: post.id,
        card_id: card.id,
        platform: account.platform,
        platform_label: Approvals.platform_label(account.platform),
        cover: cover,
        tab: if(cover.kind == :uploaded, do: "upload", else: "frame"),
        staged: nil,
        error: nil
      })
    else
      _ -> socket
    end
  end

  defp close_cover_picker(socket),
    do: socket |> cancel_cover_uploads() |> assign(:cover_picker, nil)

  defp update_cover_picker(%{assigns: %{cover_picker: %{} = picker}} = socket, fun),
    do: assign(socket, :cover_picker, fun.(picker))

  defp update_cover_picker(socket, _fun), do: socket

  defp cancel_cover_uploads(socket) do
    Enum.reduce(socket.assigns.uploads.cover.entries, socket, fn entry, acc ->
      cancel_upload(acc, :cover, entry.ref)
    end)
  end

  # A refusal keeps the picker open with the reason under the control.
  defp apply_cover(socket, post_id, attrs) do
    with {:ok, profile, user_id} <- authorize(socket),
         {:ok, post} <- Social.set_cover(profile.org_id, user_id, post_id, attrs) do
      case Approvals.live_card(post.id) do
        %{id: card_id} ->
          send_update(PlatformWeb.SocialCardComponent, id: "queue-card-" <> card_id)

        nil ->
          :ok
      end

      close_cover_picker(socket)
    else
      {:error, reason} -> update_cover_picker(socket, &%{&1 | error: cover_error_copy(reason)})
    end
  end

  defp cover_error_copy(%Ecto.Changeset{} = changeset) do
    Enum.find_value([:cover_file_id, :cover_offset_ms], "That cover can't be used.", fn field ->
      case Keyword.get_values(changeset.errors, field) do
        [{message, opts} | _] -> PlatformWeb.CoreComponents.translate_error({message, opts})
        [] -> nil
      end
    end)
  end

  defp cover_error_copy(:post_locked), do: "This post is past approval, so its cover is fixed."
  defp cover_error_copy(reason), do: PlatformWeb.SocialCardComponent.refusal_copy(reason)

  # An uploaded image is stored as soon as it arrives (a file of the
  # profile's project, through core's Files), then staged in the picker for
  # "Use this cover". Its pixel size says whether Instagram will crop it.
  defp handle_cover_progress(:cover, entry, socket) do
    if entry.done? do
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, store_cover_image(socket, path, entry)}
        end)

      case result do
        {:ok, staged} ->
          {:noreply, update_cover_picker(socket, &%{&1 | staged: staged, error: nil})}

        {:error, message} ->
          {:noreply, update_cover_picker(socket, &%{&1 | staged: nil, error: message})}
      end
    else
      {:noreply, socket}
    end
  end

  defp store_cover_image(socket, path, entry) do
    bytes = File.read!(path)
    content_type = cover_content_type(entry)

    with {:ok, profile, user_id} <- authorize(socket),
         {:ok, project} <- Social.render_project(profile),
         {:ok, file} <- store_or_reuse(project, bytes, entry.client_name, content_type, user_id) do
      {:ok,
       %{
         file_id: file.id,
         name: entry.client_name,
         size: byte_size(bytes),
         nine_sixteen?: Platform.Social.CoverImage.nine_sixteen?(bytes)
       }}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, "That image could not be stored. Try again."}
    end
  end

  # The same image uploaded again is the project's existing file: core's
  # Files keeps one row per content hash in a project, and only dedupes an
  # INGESTED sibling itself (a cover is stored without ingestion).
  defp store_or_reuse(project, bytes, name, content_type, user_id) do
    case Platform.Files.add_bytes(project, bytes, name, content_type,
           uploaded_by_user_id: user_id,
           ingest: false
         ) do
      {:ok, file, _deduplicated?} ->
        {:ok, file}

      {:error, %Ecto.Changeset{}} = error ->
        hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

        project.id
        |> Platform.Files.list_files_for_project(content_type: content_type, limit: nil)
        |> Enum.find(&(&1.content_hash == hash))
        |> case do
          nil -> error
          file -> {:ok, file}
        end

      error ->
        error
    end
  end

  defp cover_content_type(%{client_name: name}) do
    if name |> Path.extname() |> String.downcase() == ".png", do: "image/png", else: "image/jpeg"
  end

  # The upload's refusal, in the cover rule's own words where it has one.
  defp cover_upload_error(:not_accepted), do: Platform.Social.Cover.not_image_message()
  defp cover_upload_error(:too_large), do: "cover image must be under 15 MB"
  defp cover_upload_error(:too_many_files), do: "choose one image"
  defp cover_upload_error(_), do: "That image could not be uploaded."

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
      <%= cond do %>
        <% @landing -> %>
          <.invite_landing landing={@landing} />
        <% @profile -> %>
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
            <div
              :if={@can_create? and @create_open?}
              phx-window-keydown="close_create"
              phx-key="escape"
            >
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
                <span
                  :if={key == "clips"}
                  class="ml-1 text-base-content/70"
                  data-role="social-clips-count"
                >
                  {if @clips_count > 0, do: @clips_count}
                </span>
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
              <div
                :if={@queue_refused? or @queue_filter}
                role="group"
                aria-label="Filter the queue"
                class="mb-3 flex flex-wrap gap-2"
                data-role="social-queue-filter"
              >
                <button
                  :for={{key, label} <- queue_filter_labels()}
                  type="button"
                  phx-click="queue_filter"
                  phx-value-filter={key}
                  aria-pressed={to_string(@queue_filter == key)}
                  data-role="social-queue-chip"
                  data-filter={key}
                  class={[
                    "btn btn-sm rounded-full text-base-content",
                    if(@queue_filter == key,
                      do: "btn-active border-base-content",
                      else: "btn-outline border-edge"
                    )
                  ]}
                >
                  {label}
                </button>
              </div>
              <div :if={@queue_empty?} class="space-y-3">
                <p class="text-base-content/70" data-role="social-empty">
                  {empty_queue_copy(@profile, @accounts_empty?, @queue_filter)}
                </p>
                <button
                  :if={@accounts_empty? and @queue_filter != "not_published"}
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
                      cover_controls={true}
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
              <.cover_picker :if={@cover_picker} picker={@cover_picker} upload={@uploads.cover} />
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
            <div class={[@tab != "clips" && "hidden"]} data-pane="clips">
              <.live_component
                module={PlatformWeb.SocialClipsReview}
                id="social-clips-review"
                profile={@profile}
                user_id={@user.id}
                view={@clips_view}
                clip_id={@clips_clip_id}
              />
              <.live_component
                :if={@clips_view == "library"}
                module={PlatformWeb.SocialClipsLibrary}
                id="social-clips-library"
              />
              <.live_component module={PlatformWeb.SocialClipNew} id="social-clip-new" />
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
              <div
                :if={@can_edit? and not @zernio_blocks_connect? and @connectable_platforms != []}
                class="mb-3 flex flex-wrap items-start gap-2"
              >
                <.add_account
                  open?={@add_open?}
                  form={@add_form}
                  options={platform_options(@connectable_platforms)}
                />
                <button
                  type="button"
                  class="btn btn-secondary btn-sm"
                  phx-click="open_invite"
                  data-role="social-invite-open"
                >
                  Invite someone to connect
                </button>
              </div>
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
                    owner={row.owner}
                    can_edit?={@can_edit?}
                    can_connect?={@can_edit? and not @zernio_blocks_connect?}
                  />
                  <p
                    :if={row.connect_error}
                    role="alert"
                    class="flex w-full basis-full items-start gap-2 text-sm text-error"
                    data-role="social-account-connect-error"
                  >
                    <.icon name="hero-exclamation-triangle-micro" class="mt-0.5 size-4 shrink-0" />
                    <span>{row.connect_error}</span>
                  </p>
                  <.remove_panel
                    :if={@can_edit? and row.removal}
                    account={row.account}
                    preview={row.removal}
                  />
                </li>
              </ul>
              <section
                :if={@can_edit? and not @invites_empty?}
                class="mt-4"
                aria-labelledby="social-invites-heading"
                data-role="social-invites"
              >
                <h3 id="social-invites-heading" class="mb-2 text-sm font-semibold">
                  Pending invites
                </h3>
                <ul
                  id="social-invite-rows"
                  phx-update="stream"
                  class="divide-y divide-base-300 rounded-lg border border-base-300 bg-base-100"
                >
                  <li
                    :for={{dom_id, invite} <- @streams.invites}
                    id={dom_id}
                    class="flex flex-wrap items-center gap-x-3 gap-y-2 px-3 py-2"
                    data-role="social-invite-row"
                  >
                    <.invite_row invite={invite} />
                  </li>
                </ul>
              </section>
              <.invite_dialog
                :if={@can_edit? and @invite_dialog}
                dialog={@invite_dialog}
                options={platform_options(@connectable_platforms)}
              />
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
                project_setting={@project_setting}
              />
            </div>
          </section>
          <.post_detail :if={@detail} detail={@detail} />
        <% true -> %>
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
  defp empty_queue_copy(profile, _accounts_empty?, "not_published"),
    do: "Every approved post on #{profile.name} went out."

  defp empty_queue_copy(profile, true, _filter),
    do: "Nothing waiting for approval on #{profile.name}. Connect an account to start."

  defp empty_queue_copy(profile, _accounts_empty?, _filter),
    do: "Nothing waiting for approval on #{profile.name}."

  defp queue_filter_labels,
    do: [{"needs_approval", "Needs approval"}, {"not_published", "Not published"}]

  defp tab_labels(counts, profile) do
    [
      {"queue", "Queue (#{count(counts, profile)})"},
      {"calendar", "Calendar"},
      {"clips", "Clips"},
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
    <div data-role="social-add-account-control">
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
  attr :owner, :map, default: nil
  attr :can_edit?, :boolean, required: true
  attr :can_connect?, :boolean, required: true

  defp account_row(assigns) do
    assigns = assign(assigns, :mode_labels, @mode_labels)

    ~H"""
    <span class="flex min-w-0 basis-full flex-wrap items-center gap-x-3 gap-y-1 sm:flex-1 sm:basis-auto sm:flex-nowrap">
      <span class="w-20 shrink-0 whitespace-nowrap font-mono text-xs uppercase">
        {@account.platform}
      </span>
      <span
        class={[
          "text-sm",
          if(@owner,
            do: "min-w-0 flex-1 truncate sm:max-w-[60%] sm:flex-none sm:shrink-0",
            else: "min-w-0 flex-1 truncate"
          )
        ]}
        data-role="social-account-handle"
      >
        {@account.handle}
      </span>
      <%!-- The owner line (pill-on-exception): only owned accounts carry
           it. The account name keeps its width; the owner gives up space. --%>
      <span
        :if={@owner}
        class="flex min-w-0 basis-full items-center gap-1.5 pl-[5.75rem] text-sm text-base-content/70 sm:flex-1 sm:basis-auto sm:pl-0"
        data-role="social-account-owner"
      >
        <span class="grid size-5 shrink-0 place-items-center overflow-hidden rounded-full bg-neutral text-[10px] text-neutral-content">
          <img :if={@owner.avatar_url} src={@owner.avatar_url} alt="" class="size-5 object-cover" />
          <span :if={!@owner.avatar_url}>{initial(@owner.name)}</span>
        </span>
        <span class="min-w-0 truncate">Owner: {@owner.name}</span>
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

  attr :platform, :string, required: true
  attr :class, :string, default: "size-4"

  # LinkedIn's mark in currentColor (base-content, never brand blue); other
  # platforms get a generic globe.
  defp platform_icon(%{platform: "linkedin"} = assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" class={["shrink-0 fill-current", @class]} aria-hidden="true">
      <path d="M20.45 20.45h-3.56v-5.57c0-1.33-.02-3.04-1.85-3.04-1.85 0-2.14 1.45-2.14 2.94v5.67H9.35V9h3.41v1.56h.05c.48-.9 1.64-1.85 3.37-1.85 3.6 0 4.27 2.37 4.27 5.46v6.28zM5.34 7.43a2.06 2.06 0 1 1 0-4.13 2.06 2.06 0 0 1 0 4.13zM7.12 20.45H3.56V9h3.56v11.45zM22.22 0H1.77C.79 0 0 .77 0 1.73v20.54C0 23.23.79 24 1.77 24h20.45c.98 0 1.78-.77 1.78-1.73V1.73C24 .77 23.2 0 22.22 0z" />
    </svg>
    """
  end

  defp platform_icon(assigns) do
    ~H"""
    <.icon name="hero-globe-alt" class={"shrink-0 " <> @class} />
    """
  end

  attr :invite, :map, required: true

  # A pending invite row. There is no Copy link here: only the token's
  # sha256 is stored, so the link exists once, in the dialog that made it.
  defp invite_row(assigns) do
    ~H"""
    <span class="flex min-w-0 flex-1 flex-wrap items-center gap-x-2 gap-y-0.5">
      <.platform_icon platform={@invite.platform} />
      <span class="shrink-0 text-sm">Invite for {platform_label(@invite.platform)}</span>
      <span
        class={[
          "whitespace-nowrap text-sm",
          if(@invite.expiring?, do: "text-warning", else: "text-base-content/70")
        ]}
        data-role="social-invite-expiry"
        data-expiring={to_string(@invite.expiring?)}
      >
        Expires {@invite.expires_on}
      </span>
    </span>
    <button
      type="button"
      class="btn btn-ghost btn-sm shrink-0"
      phx-click="cancel_invite"
      phx-value-id={@invite.id}
      data-confirm="Cancel this invite? The link stops working."
      data-role="social-invite-cancel"
    >
      Cancel
    </button>
    """
  end

  attr :picker, :map, required: true
  attr :upload, :any, required: true

  # The cover picker (task 01a165ec stage 4, design canvas 01a165ec-76e8):
  # a dialog from sm up, a bottom sheet below. Two neutral segmented tabs;
  # each tab has its own "Use this cover", the only primary on the surface.
  # The frame tab's scrubber is the CoverPicker hook's (phx-update=ignore):
  # it draws the filmstrip in the browser and pushes `cover_frame`.
  defp cover_picker(assigns) do
    ~H"""
    <div
      class="modal modal-open modal-bottom sm:modal-middle"
      role="dialog"
      aria-modal="true"
      aria-labelledby="social-cover-title"
      phx-window-keydown="cover_close"
      phx-key="escape"
      data-role="social-cover-picker"
      data-tab={@picker.tab}
    >
      <div class="modal-box max-h-[95vh] border border-base-300 bg-base-100 p-4 sm:max-w-md sm:p-5">
        <div class="mb-3 flex items-center justify-between gap-2">
          <h2 id="social-cover-title" class="text-lg font-semibold">Cover</h2>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square"
            phx-click="cover_close"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div
          role="tablist"
          aria-label="Cover source"
          class="mb-3 grid grid-cols-2 gap-1 rounded-lg border border-base-300 bg-base-200 p-1"
          data-role="social-cover-tabs"
        >
          <button
            :for={{key, label} <- [{"frame", "Pick a frame"}, {"upload", "Upload image"}]}
            type="button"
            role="tab"
            aria-selected={to_string(@picker.tab == key)}
            phx-click="cover_tab"
            phx-value-tab={key}
            data-role="social-cover-tab"
            data-tab={key}
            class={[
              "min-h-10 rounded-md px-3 text-[15px]",
              if(@picker.tab == key,
                do: "bg-base-100 font-medium text-base-content shadow-sm",
                else: "text-subtle"
              )
            ]}
          >
            {label}
          </button>
        </div>

        <%= if @picker.tab == "frame" do %>
          <div
            id={"social-cover-scrubber-#{@picker.post_id}"}
            phx-hook="CoverPicker"
            phx-update="ignore"
            data-role="social-cover-scrubber"
            data-post-id={@picker.post_id}
            data-src={@picker.cover.video_src}
            data-offset-ms={@picker.cover.offset_ms || 0}
            data-duration-ms={@picker.cover.duration_ms}
          >
            <.cover_well>
              <video
                data-cover-preview
                src={@picker.cover.video_src <> "#t=" <> seconds(@picker.cover.offset_ms || 0)}
                muted
                playsinline
                preload="metadata"
                class="absolute inset-0 h-full w-full object-contain"
              >
              </video>
            </.cover_well>
            <div
              data-cover-strip
              role="slider"
              tabindex="0"
              aria-label="Cover frame"
              aria-valuemin="0"
              aria-valuemax={(@picker.cover.duration_ms || 0) / 1000}
              aria-valuenow={(@picker.cover.offset_ms || 0) / 1000}
              aria-valuetext={timecode(@picker.cover.offset_ms || 0, @picker.cover.duration_ms)}
              class="relative mt-3 h-14 cursor-pointer touch-none select-none overflow-hidden rounded-md border border-base-300 bg-base-300 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
            >
              <div data-cover-frames class="flex h-full w-full"></div>
              <div
                data-cover-playhead
                aria-hidden="true"
                class="pointer-events-none absolute inset-y-0 left-0 w-10 -translate-x-1/2 rounded border-2 border-base-content"
              >
                <div class="absolute inset-y-0 left-1/2 w-0.5 -translate-x-1/2 bg-base-content"></div>
              </div>
            </div>
            <p
              data-cover-timecode
              data-role="social-cover-timecode"
              class="mt-2 text-center font-mono text-sm tabular-nums"
            >
              {timecode(@picker.cover.offset_ms || 0, @picker.cover.duration_ms)}
            </p>
          </div>
          <.cover_notes picker={@picker} />
          <div class="modal-action mt-3 items-center">
            <button
              type="button"
              class="btn btn-ghost"
              phx-click="cover_reset"
              data-role="social-cover-reset"
            >
              Reset to first frame
            </button>
            <button
              type="button"
              class="btn btn-primary ml-auto"
              phx-click={
                JS.dispatch("cover:confirm", to: "#social-cover-scrubber-#{@picker.post_id}")
              }
              data-role="social-cover-use"
            >
              Use this cover
            </button>
          </div>
        <% else %>
          <form
            id="social-cover-upload"
            phx-change="cover_upload_validate"
            phx-submit="cover_upload_save"
            data-role="social-cover-upload"
          >
            <.cover_well>
              <img
                :if={@picker.staged}
                src={"/files/blob/#{@picker.staged.file_id}"}
                alt="Uploaded cover"
                class="absolute inset-0 h-full w-full object-contain"
                data-role="social-cover-staged"
              />
              <img
                :if={!@picker.staged and @picker.cover.kind == :uploaded}
                src={"/files/blob/#{@picker.cover.file_id}"}
                alt="Current cover"
                class="absolute inset-0 h-full w-full object-contain"
              />
              <label
                :if={!@picker.staged and @picker.cover.kind != :uploaded}
                for={@upload.ref}
                class="absolute inset-0 flex cursor-pointer flex-col items-center justify-center gap-2 text-[15px] text-subtle"
              >
                <.icon name="hero-photo" class="size-8" /> Choose a JPG or PNG
              </label>
            </.cover_well>
            <div class="mt-3 flex flex-wrap items-center gap-2">
              <.live_file_input
                upload={@upload}
                class="file-input file-input-sm w-full max-w-full"
              />
            </div>
            <p
              :if={@picker.staged}
              data-role="social-cover-file"
              class="mt-2 truncate text-[13px] text-subtle"
            >
              {@picker.staged.name} · {file_size(@picker.staged.size)}
            </p>
            <p
              :if={@picker.staged && !@picker.staged.nine_sixteen?}
              data-role="social-cover-crop-note"
              class="mt-1 text-[13px] text-subtle"
            >
              Instagram will crop this to 9:16
            </p>
            <p
              :for={
                err <-
                  upload_errors(@upload) ++
                    Enum.flat_map(@upload.entries, &upload_errors(@upload, &1))
              }
              data-role="social-cover-error"
              class="mt-2 text-sm text-error"
            >
              {cover_upload_error(err)}
            </p>
            <.cover_notes picker={@picker} />
            <div class="modal-action mt-3 items-center">
              <button
                type="button"
                class="btn btn-ghost"
                phx-click="cover_reset"
                data-role="social-cover-reset"
              >
                Reset to first frame
              </button>
              <button
                type="submit"
                class="btn btn-primary ml-auto"
                disabled={is_nil(@picker.staged)}
                data-role="social-cover-use"
              >
                Use this cover
              </button>
            </div>
          </form>
        <% end %>
      </div>
      <button type="button" class="modal-backdrop" phx-click="cover_close" aria-label="Close">
      </button>
    </div>
    """
  end

  slot :inner_block, required: true

  # The 9:16 preview well: the full frame, with the profile-grid crop (3:4,
  # so 12.5% top and bottom) drawn as a dimmed band. At most 60vh tall, and
  # shorter on a short screen so "Use this cover" stays in view.
  defp cover_well(assigns) do
    ~H"""
    <div
      data-role="social-cover-well"
      class="relative mx-auto aspect-[9/16] max-h-[min(60vh,100dvh_-_25rem)] w-full max-w-[min(100%,calc(min(60vh,100dvh_-_25rem)*9/16))] overflow-hidden rounded-lg bg-base-200"
    >
      {render_slot(@inner_block)}
      <div
        aria-hidden="true"
        data-role="social-cover-crop-guide"
        class="pointer-events-none absolute inset-x-0 top-0 h-[12.5%] bg-base-content/40"
      >
      </div>
      <div
        aria-hidden="true"
        class="pointer-events-none absolute inset-x-0 bottom-0 h-[12.5%] bg-base-content/40"
      >
      </div>
    </div>
    """
  end

  attr :picker, :map, required: true

  # The platform line, then a refusal under the control.
  defp cover_notes(assigns) do
    ~H"""
    <p data-role="social-cover-platform" class="mt-2 text-[13px] text-subtle">
      {cover_platform_line(@picker.platform, @picker.platform_label, @picker.tab)}
    </p>
    <p
      :if={@picker.error}
      role="alert"
      data-role="social-cover-error"
      class="mt-2 text-sm text-error"
    >
      {@picker.error}
    </p>
    """
  end

  defp cover_platform_line("instagram", _label, _tab), do: "Instagram uses this cover"
  defp cover_platform_line("youtube", _label, "frame"), do: "YouTube uses only an uploaded cover"
  defp cover_platform_line("youtube", _label, _tab), do: "YouTube uses this cover"
  defp cover_platform_line(_platform, label, _tab), do: "#{label} picks its own cover"

  # 7400 -> "7.4", 7000 -> "7": a media fragment's seconds.
  defp seconds(ms) when rem(ms, 1000) == 0, do: Integer.to_string(div(ms, 1000))
  defp seconds(ms), do: :erlang.float_to_binary(ms / 1000, [:short])

  # "0:07.40 / 0:42" (the hook keeps it current while scrubbing).
  defp timecode(ms, duration_ms) do
    cs = div(ms, 10)
    s = div(cs, 100)

    head =
      "#{div(s, 60)}:#{pad2(rem(s, 60))}.#{pad2(rem(cs, 100))}"

    case duration_ms do
      d when is_integer(d) and d > 0 ->
        head <> " / " <> PlatformWeb.SocialCardComponent.clock_ms(d)

      _ ->
        head
    end
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp file_size(bytes) when bytes >= 1_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  defp file_size(bytes) when bytes >= 1_000, do: "#{round(bytes / 1_000)} KB"
  defp file_size(bytes), do: "#{bytes} B"

  attr :dialog, :map, required: true
  attr :options, :list, required: true

  # A dialog from sm up, a bottom sheet below (daisy modal-bottom).
  defp invite_dialog(assigns) do
    ~H"""
    <div
      class="modal modal-open modal-bottom sm:modal-middle"
      role="dialog"
      aria-modal="true"
      aria-labelledby="social-invite-title"
      phx-window-keydown="close_invite"
      phx-key="escape"
      data-role="social-invite-dialog"
      data-step={@dialog.step}
    >
      <div class="modal-box border border-base-300 bg-base-100">
        <div class="mb-3 flex items-center justify-between gap-2">
          <h2 id="social-invite-title" class="text-lg font-semibold">
            Invite someone to connect
          </h2>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square"
            phx-click="close_invite"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        <%= if @dialog.step == :form do %>
          <p class="mb-3 text-sm text-base-content/70">
            They connect their own account and approve every post under their name.
          </p>
          <.form
            for={@dialog.form}
            id="social-invite-form"
            phx-submit="create_invite"
            class="space-y-1"
            data-role="social-invite-form"
          >
            <.input
              field={@dialog.form[:platform]}
              type="select"
              label="Platform"
              options={@options}
              data-role="social-invite-platform"
            />
            <.input
              field={@dialog.form[:ttl_days]}
              type="select"
              label="Link expires after"
              options={ttl_options()}
              data-role="social-invite-ttl"
            />
            <div class="modal-action mt-3">
              <button type="button" class="btn btn-ghost" phx-click="close_invite">Cancel</button>
              <button
                type="submit"
                class="btn btn-secondary"
                phx-disable-with="Creating..."
                data-role="social-invite-create"
              >
                Create link
              </button>
            </div>
          </.form>
        <% else %>
          <label for="social-invite-url" class="label mb-1 text-sm font-medium">Invite link</label>
          <div class="flex gap-2">
            <input
              id="social-invite-url"
              type="text"
              readonly
              value={@dialog.url}
              class="input min-w-0 flex-1 font-mono text-sm"
              data-role="social-invite-url"
            />
            <button
              id="social-invite-copy"
              type="button"
              class="btn btn-secondary"
              phx-hook="CopyToClipboard"
              data-clipboard-text={@dialog.url}
              data-role="social-invite-copy"
            >
              Copy
            </button>
          </div>
          <p class="mt-2 text-sm text-base-content/70" data-role="social-invite-terms">
            Single use. Works for a signed-in Burrow user. Expires {@dialog.expires_on}.
          </p>
          <div class="modal-action mt-3">
            <button type="button" class="btn btn-ghost" phx-click="close_invite">Done</button>
          </div>
        <% end %>
      </div>
      <button type="button" class="modal-backdrop" phx-click="close_invite" aria-label="Close">
      </button>
    </div>
    """
  end

  attr :landing, :map, required: true

  # The invitee landing page: ONE base-100 card on base-200, rendered
  # instead of the profile UI. Continue / Try again are the only actions,
  # and they exist only in the :ready / :failed states.
  defp invite_landing(assigns) do
    ~H"""
    <div class="flex min-h-full flex-1 items-start justify-center bg-base-200 px-4 py-8 sm:items-center sm:py-12">
      <section
        class="w-full max-w-md rounded-2xl border border-base-300 bg-base-100 p-6 sm:p-8"
        data-role="social-invite-landing"
        data-state={@landing.state}
      >
        <%= case @landing.state do %>
          <% :checking -> %>
            <p class="text-base-content/70">Checking your connection...</p>
          <% :signed_out -> %>
            <h1 class="text-2xl font-semibold">You've been invited to connect an account</h1>
            <p class="mt-2 text-base-content/70">Sign in to Burrow to see who invited you.</p>
            <a
              href="/auth/login"
              class="btn btn-primary mt-6 w-full"
              data-role="social-invite-sign-in"
            >
              Sign in to continue
            </a>
          <% :invalid -> %>
            <p class="text-base-content" data-role="social-invite-message">{@landing.message}</p>
          <% state -> %>
            <.landing_brand brand={@landing.brand} />
            <.landing_body landing={@landing} state={state} />
        <% end %>
      </section>
    </div>
    """
  end

  attr :brand, :string, required: true

  defp landing_brand(assigns) do
    ~H"""
    <div class="avatar avatar-placeholder mb-4">
      <div class="size-12 rounded-xl bg-neutral text-neutral-content">
        <span class="text-lg font-semibold">{initial(@brand)}</span>
      </div>
    </div>
    """
  end

  attr :landing, :map, required: true
  attr :state, :atom, required: true

  defp landing_body(%{state: :ready} = assigns) do
    ~H"""
    <h1 class="text-2xl font-semibold" data-role="social-invite-headline">
      Connect your {@landing.platform} to {@landing.brand}
    </h1>
    <p class="mt-1 text-sm text-base-content/70" data-role="social-invite-meta">
      {@landing.inviter} invited you. Link expires {@landing.expires_on}.
    </p>
    <ul class="mt-5 list-disc space-y-2 pl-5">
      <li>Agents can draft posts for your {@landing.platform} account.</li>
      <li class="font-semibold">Nothing posts until you approve it. Drafts arrive in your DM.</li>
      <li>You can disconnect any time from Connections.</li>
    </ul>
    <.landing_error error={@landing.error} />
    <div class="mt-6 flex flex-col gap-2">
      <button
        type="button"
        class="btn btn-primary w-full"
        phx-click="invite_continue"
        phx-disable-with="Opening LinkedIn..."
        data-role="social-invite-continue"
      >
        <.platform_icon platform="linkedin" class="size-4 text-base-content" />
        Continue to {@landing.platform}
      </button>
      <a href="/" class="btn btn-ghost w-full" data-role="social-invite-not-now">Not now</a>
    </div>
    """
  end

  defp landing_body(%{state: :expired} = assigns) do
    ~H"""
    <div role="status" class="alert alert-warning" data-role="social-invite-message">
      <.icon name="hero-clock" class="size-5 shrink-0" />
      <span>
        This invite expired on {@landing.expires_on}. Ask {@landing.inviter} for a new one.
      </span>
    </div>
    """
  end

  defp landing_body(%{state: :cancelled} = assigns) do
    ~H"""
    <p class="text-base-content" data-role="social-invite-message">
      This invite was cancelled. Ask {@landing.inviter} for a new one.
    </p>
    """
  end

  defp landing_body(%{state: :used} = assigns) do
    ~H"""
    <p class="text-base-content" data-role="social-invite-message">
      This invite was already used.
    </p>
    <a
      :if={@landing.viewer_used?}
      href={"/m/social?" <> URI.encode_query(%{"tab" => "connections", "profile" => @landing.profile_id})}
      class="link mt-3 inline-block"
      data-role="social-invite-account-link"
    >
      See your connected account
    </a>
    """
  end

  defp landing_body(%{state: :success} = assigns) do
    ~H"""
    <p class="text-base-content" data-role="social-invite-message">
      Your {@landing.platform} is connected to {@landing.brand}. Drafts will come to your DM.
    </p>
    <a
      :if={@landing.dm_path}
      href={@landing.dm_path}
      class="btn btn-primary mt-6 w-full"
      data-role="social-invite-dm-link"
    >
      Open your DM
    </a>
    """
  end

  defp landing_body(%{state: :failed} = assigns) do
    ~H"""
    <p class="text-base-content" data-role="social-invite-message">
      {@landing.platform} didn't finish connecting, so nothing changed. Your invite still works until {@landing.expires_on}.
    </p>
    <.landing_error error={@landing.error} />
    <button
      type="button"
      class="btn btn-primary mt-6 w-full"
      phx-click="invite_retry"
      phx-disable-with="Opening LinkedIn..."
      data-role="social-invite-retry"
    >
      Try again
    </button>
    """
  end

  attr :error, :string, default: nil

  defp landing_error(assigns) do
    ~H"""
    <p
      :if={@error}
      role="alert"
      class="mt-4 flex items-center gap-1.5 text-sm text-base-content"
      data-role="social-invite-error"
    >
      <.icon name="hero-exclamation-circle" class="size-4 shrink-0 text-error" />
      {@error}
    </p>
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
  attr :project_setting, :map, default: nil

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
      <SocialProjectSetting.readonly :if={@project_setting} setting={@project_setting} />
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
    <SocialProjectSetting.row :if={@project_setting} setting={@project_setting} />
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
