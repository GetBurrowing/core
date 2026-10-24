defmodule PlatformWeb.SocialConnectionsTab do
  @moduledoc """
  The Connections tab (extracted from `PlatformWeb.SocialLive` by Social
  authoring 1/11, no behaviour change). Per brand only (`all_brands?/0`
  false): accounts belong to one profile.

  ## Adding an account (task 01a14801)

  ONE "+ Add account" control, shown only to an approver of the profile
  (`@can_edit?`), only when Connect is not blocked on the Zernio key, and
  only when the publisher can connect something. Its picker offers exactly
  `Platform.Social.connectable_platforms/0`. `add_account` re-checks through
  `authorize/1`, then `Platform.Social.add_account/4` (which ensures the
  vendor profile first and re-checks the approver itself), then the
  publisher's `connect_url/2`, then an external redirect. A connect failure
  AFTER the row exists re-streams the rows so it shows with Connect; the row
  is kept and retried, never deleted. Any connect failure names its reason
  (the vendor's status and message, never the URL or key) on the clicked
  row itself as well as in the pane's notice line. `connect_account` also
  runs `Platform.Social.ensure_provider_profile/2` first. The vendor URL
  and the key are never logged.

  While the Zernio publisher is selected and no key is set, the pane shows
  a notice pointing at Settings and hides Connect/Reconnect.

  ## The OAuth return (task 01a14807)

  The vendor sends the browser back to `/m/social` with its result in the
  query string; the LiveView is nested, so core forwards it as a bounded
  map of UNTRUSTED strings in `session["query"]`, read through ONE parser,
  `return_params/1`, from `PlatformWeb.SocialLive.mount/3` (connected
  mount, live humans only: the vendor is asked once).

    * Success (`profileId` + `accountId`, both shape-checked; anything else
      is malformed, with no request): the profile must be one of the
      viewer's VISIBLE profiles with that `provider_profile_ref`, else a
      "doesn't match" notice and no request. Then `authorize/1` and
      `Platform.Social.complete_connect/4` (approver re-checked inside).
      The URL's username and platform are never used for a write.
    * Failure (`error` present): a notice naming the code when it passes the
      shape check. No request, no write.

  The URL keeps the parameters after landing, so a reload replays the
  return; `complete_connect/4` is idempotent, so that is safe.

  ## Picking up connections on opening Connections (task 01a14807)

  `on_select/1`, and `load/1` while the tab already is current, reconcile:
  only on a connected socket, for a viewer who passes `authorize/1`, on a
  profile with a `provider_profile_ref`, while a never-connected row is
  listed, or while a connected row has a nil `platform_account_type` (task
  01a1653a) and this LiveView has not asked for THIS profile yet. Rows the
  vendor does not list stay as they are, with Connect; they are never
  deleted, and no row is created for a vendor account we have no row for.

  ## Employee accounts: owner line, invites (task 01a14ce1)

  An owned account's row carries `Owner: <name>`. An approver gets "Invite
  someone to connect", a dialog (bottom sheet below sm) that calls
  `Platform.Social.create_invite/5` and shows the link ONCE, and the
  pending invites with Cancel (`cancel_invite/3`). Only the token's hash is
  stored, so a pending row cannot re-show its link. The invitee side is
  `PlatformWeb.SocialInviteLanding`.

  ## Health first (Social authoring 9/11, task 01a16c51-9cc5)

  Rows come from `Platform.Social.Health`, the SAME computation as the top
  bar's health dot: ordered down, then warn, then ok, then by name. Each row
  shows a state pill with text and an icon (readable without colour), the
  reasons in plain words, "Last posted 2d ago" (linked to the live post when
  the vendor gave a URL), the approval mode, the owner or the approvers by
  name, and the drafting agent when the profile has one. Each reason has at
  most ONE fix, through an existing handler: Connect/Reconnect
  (`connect_account`), or Retry for a publish refused before the vendor
  (`retry_publish`, `Platform.Social.Publishing.retry_publish/3`). Fixes are
  approver-only; anyone else reads the same health with no buttons. On a
  phone the row stacks and the fix is full width.
  """

  use PlatformWeb.SocialTab

  alias Phoenix.LiveView.JS
  alias Platform.Accounts.User
  alias Platform.Social
  alias Platform.Social.{Account, Health, Publisher, Publishing}
  alias PlatformWeb.{SocialInviteLanding, SocialScope}

  @approver_refusals [
    :not_an_approver,
    :not_a_human,
    :approver_archived,
    :approver_no_access,
    :not_the_owner
  ]

  # The invite dialog's expiry choices, in days; 7 is the default.
  @invite_ttl_days [1, 3, 7, 14]

  @events ~w(connect_account open_add_account close_add_account add_account set_mode
             open_remove cancel_remove remove_account open_invite close_invite
             create_invite cancel_invite retry_publish)

  @impl true
  def enabled?, do: true

  @impl true
  def events, do: @events

  @impl true
  def init(socket) do
    socket
    |> assign(:type_checked_profile_ids, MapSet.new())
    |> assign(:removing, nil)
    |> assign(:invite_dialog, nil)
  end

  # Connections for the current profile. `can_edit?` (set by
  # SocialScope.load_profile/2) is ONLY for rendering; every write handler
  # re-checks through `authorize/1`.
  @impl true
  def load(%{assigns: %{profile: nil}} = socket) do
    socket
    |> assign(:removing, nil)
    |> assign(:accounts_empty?, true)
    |> assign(:pending_accounts?, false)
    |> assign(:untyped_accounts?, false)
    |> assign(:connectable_platforms, [])
    |> assign(:add_open?, false)
    |> assign(:add_form, add_form([]))
    |> assign(:invite_dialog, nil)
    |> assign(:invites_empty?, true)
    |> assign(:row_context, %{approvers: [], agent: nil})
    |> stream(:accounts, [], reset: true)
    |> stream(:invites, [], reset: true)
  end

  def load(%{assigns: %{profile: profile}} = socket) do
    accounts = Social.list_accounts(profile.org_id, profile_id: profile.id)
    platforms = Social.connectable_platforms()

    socket
    |> assign(:removing, nil)
    |> assign(:accounts_empty?, accounts == [])
    |> assign_reconcile_flags(accounts)
    |> assign(:connectable_platforms, platforms)
    |> assign(:add_open?, false)
    |> assign(:add_form, add_form(platforms))
    |> assign(:invite_dialog, nil)
    |> assign(:row_context, row_context(profile))
    |> stream(:accounts, account_items(accounts, nil), reset: true)
    |> restream_invites()
    |> maybe_reconcile()
  end

  @impl true
  def on_select(socket), do: maybe_reconcile(socket)

  # Connect / Reconnect: an approver of the profile only (re-checked here,
  # server-side), through the configured Publisher's connect_url/2 with this
  # install's own /m/social as the redirect. The vendor URL is never logged.
  @impl true
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
       |> stream_insert(:accounts, single_item(account, socket.assigns.removing))}
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
       |> stream_insert(:accounts, single_item(preview.account, removing))}
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
       |> stream_delete(:accounts, %{id: account.id})
       |> assign_account_flags()
       |> SocialScope.assign_profiles(SocialScope.visible_profiles(socket))
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

  # Retry a publish refused before the vendor (the health reason's fix):
  # approvers only, and only for a post on one of THIS profile's accounts;
  # `Publishing.retry_publish/3` re-checks the approver and runs the whole
  # publish guard again.
  def handle_event("retry_publish", %{"post_id" => post_id}, socket) when is_binary(post_id) do
    with {:ok, profile, user_id} <- authorize(socket),
         %{account_id: account_id} <- Social.get_post(profile.org_id, post_id),
         %Account{} <- profile_account(profile, account_id) do
      result = Publishing.retry_publish(profile.org_id, post_id, user_id)
      {:noreply, socket |> restream_accounts() |> notice(retry_copy(result))}
    else
      {:error, :not_an_approver} ->
        {:noreply, notice(socket, "Only an approver of this profile can change it.")}

      _ ->
        {:noreply, notice(socket, "That post could not be retried. Try again.")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp retry_copy({:ok, _post}), do: "Retried. The post is on its way."

  defp retry_copy({:error, {:wait_until, at}}),
    do: "Still rate limited. Retry after #{Calendar.strftime(at, "%H:%M")} UTC."

  defp retry_copy({:error, {:publish_failed, _}}),
    do: "Retried, and the platform refused it again. See the reason on the row."

  defp retry_copy({:error, :not_refused}), do: "That post is no longer waiting for a retry."
  defp retry_copy(_error), do: "Retried, but it still can't be sent. See the reason on the row."

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

  # The stream rows in health order (`Platform.Social.Health.profile/1`:
  # down, warn, ok, then by name). `errors` maps an account id to its
  # connect failure.
  defp account_items(accounts, removing, errors \\ %{}) do
    facts = Health.facts(accounts)

    accounts
    |> Enum.map(&{&1, Health.account(&1, Map.get(facts, &1.id))})
    |> Health.profile()
    |> Map.fetch!(:accounts)
    |> Enum.map(fn {account, health} ->
      account_item(account, health, removing, Map.get(errors, account.id))
    end)
  end

  # One row re-rendered in place (its stream position is kept).
  defp single_item(account, removing) do
    facts = Health.facts([account])
    account_item(account, Health.account(account, Map.get(facts, account.id)), removing, nil)
  end

  # A stream row; `removal` is the open confirm panel's preview, else nil.
  defp account_item(account, health, removing, connect_error) do
    removal =
      case removing do
        %{account_id: id, preview: preview} when id == account.id -> preview
        _ -> nil
      end

    %{
      id: account.id,
      account: account,
      health: health,
      removal: removal,
      owner: owner_of(account),
      connect_error: connect_error
    }
  end

  # What every row of this profile shares: the approvers' names (an owned
  # account shows its owner instead) and the drafting agent, when set.
  defp row_context(profile) do
    users = Platform.Accounts.get_users_map(profile.approver_user_ids || [])

    approvers =
      for id <- profile.approver_user_ids || [],
          Map.has_key?(users, id),
          do: user_name(Map.fetch!(users, id))

    agent =
      with id when is_binary(id) <- profile.drafting_agent_id,
           %{name: name} when is_binary(name) and name != "" <-
             Platform.Repo.get(Platform.Agents.Agent, id) do
        name
      else
        _ -> nil
      end

    %{approvers: approvers, agent: agent}
  end

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

  defp connect_error_copy(%Account{platform: platform}, error) do
    "Couldn't connect #{platform_label(platform)}. " <> connect_reason(error)
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

  # Closes the open confirm panel (if any) by re-streaming its row as read
  # now; a row that is no longer live is dropped from the stream.
  defp close_removal(%{assigns: %{removing: %{account_id: id}, profile: %{} = profile}} = socket) do
    socket = assign(socket, :removing, nil)

    case profile_account(profile, id) do
      %Account{} = account -> stream_insert(socket, :accounts, single_item(account, nil))
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

  @doc """
  Re-reads and re-streams the current profile's account rows. `errors` maps
  an account id to the connect failure shown on its row. Settings calls it
  when the Zernio key gate flips (Connect/Reconnect render per row).
  """
  def restream_accounts(socket, errors \\ %{})

  def restream_accounts(%{assigns: %{profile: nil}} = socket, _errors), do: socket

  def restream_accounts(%{assigns: %{profile: profile}} = socket, errors) do
    accounts = Social.list_accounts(profile.org_id, profile_id: profile.id)
    removing = socket.assigns.removing

    socket
    |> assign(:accounts_empty?, accounts == [])
    |> assign_reconcile_flags(accounts)
    |> assign(:row_context, row_context(profile))
    |> stream(:accounts, account_items(accounts, removing, errors), reset: true)
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
  # and backfills the account type on connected rows that have none. Runs
  # only on the Connections tab with one brand in scope, on a connected
  # socket, for a viewer who passes `authorize/1`, on a profile with a
  # vendor ref, while a never-connected row is listed, or while a connected
  # row has a nil `platform_account_type` and this LiveView has not yet
  # asked for THIS profile. `reconcile_accounts/3` re-checks the approver
  # and the ref and sends nothing when there is nothing to do. Synchronous:
  # the publisher's 5s receive_timeout bounds how long the click can block.
  @doc false
  def maybe_reconcile(%{assigns: %{tab: "connections", scope: {:profile, _}} = assigns} = socket) do
    if reconcile_due?(assigns), do: reconcile(socket), else: socket
  end

  def maybe_reconcile(socket), do: socket

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

  # ── OAuth return (task 01a14807) ─────────────────────────────────────

  @vendor_id ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @error_code ~r/\A[a-z0-9_]{1,64}\z/
  @nonce ~r/\A[A-Za-z0-9_-]{16,128}\z/

  @doc """
  The ONE parser for the host's forwarded query (untrusted strings). Only
  profileId, accountId and error are read; username, error_message and
  every other key are ignored (the handle comes from the vendor list).
  """
  def return_params(%{"error" => error} = query) when is_binary(error) do
    {:return_error, %{code: shaped(error, @error_code), profile_ref: shaped(query["profileId"])}}
  end

  # An invite return (task 01a14ce1): the per-connect nonce plus the
  # vendor's ids. Authorized by the invite, not by authorize/1.
  def return_params(%{"invite_connect" => nonce} = query) do
    case {shaped(nonce, @nonce), shaped(query["profileId"]), shaped(query["accountId"])} do
      {nonce, profile_ref, account_ref}
      when is_binary(nonce) and is_binary(profile_ref) and is_binary(account_ref) ->
        {:return_invite, %{nonce: nonce, profile_ref: profile_ref, account_ref: account_ref}}

      _ ->
        :return_malformed
    end
  end

  def return_params(%{} = query)
      when is_map_key(query, "connected") or is_map_key(query, "profileId") or
             is_map_key(query, "accountId") do
    case {shaped(query["profileId"]), shaped(query["accountId"])} do
      {profile_ref, account_ref} when is_binary(profile_ref) and is_binary(account_ref) ->
        {:return_connected, %{profile_ref: profile_ref, account_ref: account_ref}}

      _ ->
        :return_malformed
    end
  end

  def return_params(_query), do: :no_return

  defp shaped(value, pattern \\ @vendor_id)
  defp shaped(value, pattern) when is_binary(value), do: if(value =~ pattern, do: value)
  defp shaped(_value, _pattern), do: nil

  # Only among the viewer's VISIBLE profiles: another org's ref is no match.
  defp return_profile(profiles, ref) when is_binary(ref),
    do: Enum.find(profiles, &(&1.provider_profile_ref == ref))

  defp return_profile(_profiles, _ref), do: nil

  @doc "Lands the vendor's return parsed by `return_params/1`."
  def handle_return(socket, _profiles, :no_return), do: socket

  def handle_return(socket, _profiles, :return_malformed) do
    socket
    |> assign(:tab, "connections")
    |> notice("That connection couldn't be read. Nothing changed. Try Connect again.")
  end

  def handle_return(socket, profiles, {:return_error, %{code: code, profile_ref: ref}}) do
    socket =
      case return_profile(profiles, ref) do
        nil -> socket
        profile -> SocialScope.load_profile(socket, profile)
      end

    reason = if code, do: " (#{code})", else: ""

    socket
    |> assign(:tab, "connections")
    |> notice("The account wasn't connected#{reason}. Try Connect again.")
  end

  def handle_return(socket, profiles, {:return_connected, params}) do
    case return_profile(profiles, params.profile_ref) do
      nil ->
        socket
        |> assign(:tab, "connections")
        |> notice("That connection doesn't match a profile you can manage. Nothing changed.")

      profile ->
        # load_profile/2 resets :notice, so the notice is set AFTER it.
        socket = socket |> SocialScope.load_profile(profile) |> assign(:tab, "connections")

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
  def handle_return(socket, profiles, {:return_invite, params}) do
    case return_profile(profiles, params.profile_ref) do
      nil ->
        assign(socket, :landing, %{state: :invalid, message: SocialInviteLanding.unusable()})

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
              dm_path: SocialInviteLanding.owner_dm_path(profile, user)
            })

          {:error, reason}
          when reason in [:not_found, :expired, :used, :cancelled, :not_the_inviter] or
                 reason in @approver_refusals ->
            assign(socket, :landing, %{state: :invalid, message: SocialInviteLanding.unusable()})

          {:error, _vendor_or_listing} ->
            SocialInviteLanding.assign_failed_landing(socket, params.nonce, user)
        end
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

  # ── Render ──────────────────────────────────────────────────────────

  @impl true
  def pane(assigns) do
    ~H"""
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
    <p :if={@accounts_empty?} class="mb-3 text-base-content" data-role="social-empty">
      No accounts yet for {@profile.name}. Add one to start posting.
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
        data-health={row.health.state}
      >
        <.health_pill state={row.health.state} />
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
        <.health_detail
          account={row.account}
          health={row.health}
          owner={row.owner}
          context={@row_context}
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
        class="flex min-w-0 basis-full items-center gap-1.5 pl-[5.75rem] text-sm text-base-content sm:flex-1 sm:basis-auto sm:pl-0"
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
    <span
      class={[
        "shrink-0",
        @account.status != "connected" && @can_connect? && "max-sm:basis-full"
      ]}
      data-role="social-account-state"
      data-state={@account.status || "none"}
    >
      <%= case @account.status do %>
        <% "connected" -> %>
          <span class="inline-flex items-center gap-1 text-sm">
            <.icon name="hero-check-circle-micro" class="size-4" /> Connected
          </span>
        <% "reauth_needed" -> %>
          <span class="flex items-center gap-2">
            <span class="badge badge-warning gap-1 whitespace-nowrap">
              <.icon name="hero-exclamation-triangle-micro" class="size-3" /> Reconnect
            </span>
            <button
              :if={@can_connect?}
              type="button"
              class="btn btn-outline btn-sm max-sm:flex-1"
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
            class="btn btn-outline btn-sm max-sm:w-full"
            phx-click="connect_account"
            phx-value-id={@account.id}
            data-role="social-account-connect"
          >
            Connect
          </button>
          <span :if={!@can_connect?} class="text-sm text-base-content">Not connected</span>
      <% end %>
    </span>
    <button
      :if={@can_edit?}
      type="button"
      class="btn btn-ghost btn-sm shrink-0 text-base-content"
      phx-click="open_remove"
      phx-value-id={@account.id}
      data-role="social-account-remove"
    >
      Remove
    </button>
    """
  end

  @health_pills %{
    down: {"badge-error", "hero-x-circle-micro", "Not working"},
    warn: {"badge-warning", "hero-exclamation-triangle-micro", "Needs attention"},
    ok: {"badge-success", "hero-check-circle-micro", "Healthy"}
  }

  attr :state, :atom, required: true

  # The state pill: text AND an icon, so it reads without colour.
  defp health_pill(assigns) do
    {tone, icon, label} = Map.fetch!(@health_pills, assigns.state)
    assigns = assign(assigns, tone: tone, icon: icon, label: label)

    ~H"""
    <span
      class={["badge badge-soft shrink-0 gap-1 whitespace-nowrap", @tone]}
      data-role="social-account-health"
      data-health={@state}
    >
      <.icon name={@icon} class="size-3.5" /> {@label}
    </span>
    """
  end

  @reason_icons %{
    down: "hero-x-circle-micro",
    warn: "hero-exclamation-triangle-micro",
    info: "hero-information-circle-micro"
  }

  attr :account, :map, required: true
  attr :health, :map, required: true
  attr :owner, :map, default: nil
  attr :context, :map, required: true
  attr :can_edit?, :boolean, required: true
  attr :can_connect?, :boolean, required: true

  # Under the row: the reasons in plain words (each with at most ONE fix,
  # approvers only), then last posted, who approves and who drafts. The
  # Connect/Reconnect of a not-connected or disconnected account is the
  # state button on the row itself, so it is not repeated here.
  defp health_detail(assigns) do
    assigns = assign(assigns, :reason_icons, @reason_icons)

    ~H"""
    <div
      class="flex w-full basis-full flex-col gap-1.5 text-sm"
      data-role="social-account-health-detail"
    >
      <ul :if={@health.reasons != []} class="flex flex-col gap-1.5">
        <li
          :for={reason <- @health.reasons}
          class="flex flex-col gap-1.5 sm:flex-row sm:items-center sm:justify-between sm:gap-3"
          data-role="social-account-reason"
          data-code={reason.code}
          data-tone={reason.tone}
        >
          <span class={[
            "flex items-start gap-1.5",
            reason.tone == :info && "text-base-content"
          ]}>
            <.icon
              name={Map.fetch!(@reason_icons, reason.tone)}
              class="mt-0.5 size-4 shrink-0"
            />
            <span>{reason.text}</span>
          </span>
          <.reason_fix
            :if={@can_edit?}
            fix={reason.fix}
            account={@account}
            can_connect?={@can_connect?}
          />
        </li>
      </ul>
      <p class="flex flex-wrap gap-x-4 gap-y-1 text-base-content">
        <span data-role="social-account-last-posted">
          <%= cond do %>
            <% @health.last_published_at && @health.last_published_url -> %>
              <a href={@health.last_published_url} target="_blank" rel="noopener" class="link">
                Last posted {ago(@health.last_published_at)}
              </a>
            <% @health.last_published_at -> %>
              Last posted {ago(@health.last_published_at)}
            <% true -> %>
              Nothing posted yet
          <% end %>
        </span>
        <span :if={!@owner} data-role="social-account-approvers">
          <%= if @context.approvers == [] do %>
            No approvers yet
          <% else %>
            Approvers: {Enum.join(@context.approvers, ", ")}
          <% end %>
        </span>
        <span :if={@context.agent} data-role="social-account-drafting-agent">
          Drafted by {@context.agent}
        </span>
      </p>
    </div>
    """
  end

  attr :fix, :any, required: true
  attr :account, :map, required: true
  attr :can_connect?, :boolean, required: true

  defp reason_fix(%{fix: {:retry, post_id}} = assigns) do
    assigns = assign(assigns, :post_id, post_id)

    ~H"""
    <button
      type="button"
      class="btn btn-outline btn-sm shrink-0 max-sm:w-full"
      phx-click="retry_publish"
      phx-value-post_id={@post_id}
      phx-disable-with="Retrying..."
      data-role="social-account-fix"
      data-fix="retry"
    >
      Retry publish
    </button>
    """
  end

  # Only for a CONNECTED account (an Instagram personal account): any other
  # state already shows Connect/Reconnect on the row.
  defp reason_fix(%{fix: :connect, account: %{status: "connected"}, can_connect?: true} = assigns) do
    ~H"""
    <button
      type="button"
      class="btn btn-outline btn-sm shrink-0 max-sm:w-full"
      phx-click="connect_account"
      phx-value-id={@account.id}
      data-role="social-account-fix"
      data-fix="connect"
    >
      Reconnect
    </button>
    """
  end

  defp reason_fix(assigns), do: ~H""

  # "2d ago": minutes under an hour, hours under a day, then days.
  defp ago(%DateTime{} = at) do
    seconds = max(DateTime.diff(DateTime.utc_now(), at), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
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
          if(@invite.expiring?, do: "text-warning", else: "text-base-content")
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
          <p class="mb-3 text-sm text-base-content">
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
          <p class="mt-2 text-sm text-base-content" data-role="social-invite-terms">
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
      <p :if={@account.status} class="mt-1 text-base-content" data-role="social-remove-reconnect">
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
end
