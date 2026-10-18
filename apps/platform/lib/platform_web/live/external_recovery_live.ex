defmodule PlatformWeb.ExternalRecoveryLive do
  @moduledoc """
  External Recovery — the root-admin surface listing external logins still
  awaiting setup, with a one-click Grant that live-applies to the waiting
  session (rbac-external-users M3 stage 4, task 019f8837).

  This is the ADMIN half of the operator's live-recovery centerpiece: an external
  user who logged in without a pre-staged grant sits on the M3 holding
  landing (`/welcome`); here an admin grants them (target org + channel(s) +
  per-org DM allowlist) and `Platform.Accounts.ExternalAdmission.recover/3`
  materializes the grant AND broadcasts `{:external_admission, :recovered,
  ...}`, which the holding tab consumes to upgrade in place — no re-login.

  NOT the archived-container `RecoveryLive` (`/admin/recovery`, task
  019f7600) — that recovers archived orgs/projects/channels, unrelated to
  external-user holding.

  ## Queue source + live channel

    * `ExternalAdmission.awaiting_setup/0` reads the durable audit-backed
      queue (M3 stage 3): recent `holding` logins, deduped, minus anyone
      already provisioned.
    * Mount subscribes to
      `Platform.Accounts.ExternalAdmissionNotifier.admin_admissions_topic/0`;
      a `{:external_admission_holding, _}` broadcast live-appends the row +
      increments a "new" badge WITHOUT a reload.

  ## Group-claim mapping editor (task 019ff7ff stage 5)

  The same page carries the IdP group value -> org mapping editor backing
  `Tenancy.resolve_org_from_groups/1`. Adding a mapping changes only what
  FUTURE holding logins pre-select — it grants nothing retroactively, and
  no membership/participant/allowlist row is ever written from here. Each
  holding row that matched nothing lists the group values it actually
  carried (or says they were not recorded) so an admin maps a real value
  instead of a guessed one.

  root-admin-only gate is inherited from the `:admin` `live_session`
  (`{PlatformWeb.LiveAuth, :ensure_admin}`).
  """
  use PlatformWeb, :live_view

  alias Platform.Accounts
  alias Platform.Accounts.ExternalAdmission
  alias Platform.Accounts.ExternalAdmissionNotifier
  alias Platform.Chat
  alias Platform.Tenancy
  alias Platform.Tenancy.ExternalGrants
  alias Platform.Tenancy.OrgGroupClaim

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        Platform.PubSub,
        ExternalAdmissionNotifier.admin_admissions_topic()
      )
    end

    socket =
      socket
      |> assign(:page_title, "External Recovery")
      |> assign(:new_count, 0)
      |> assign(:orgs, Tenancy.list_orgs())
      |> assign(:grant_spaces, Chat.list_spaces(kind: "channel"))
      |> load_queue()
      |> load_provisioned()
      |> load_group_claims()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_event("grant", params, socket) do
    %{"user_id" => user_id} = params
    admin_user = socket.assigns.current_user_record

    case Accounts.get_user(user_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That user no longer exists.")}

      target_user ->
        # An already-provisioned external user can't be re-`create_grant`'d —
        # a second insert collides on the per-email unique index. Instead of a
        # no-op, ADD the selected channels to them (idempotent participant
        # inserts). A fresh (still-holding) user goes through full recovery.
        if Tenancy.external_user?(target_user) do
          add_channels(socket, target_user, params)
        else
          do_grant(socket, admin_user, target_user, params)
        end
    end
  end

  # Task 019ff7ff stage 5 — the group-claim mapping editor. Creating a
  # mapping changes FUTURE pre-selection only: no `apply_grant`, no
  # `recover/3`, no membership write happens here. An admin still grants
  # each holding user by hand; the mapping just stops them guessing which
  # org a group value means.
  def handle_event("add_group_mapping", params, socket) do
    attrs = %{
      claim_value: Map.get(params, "claim_value"),
      org_id: presence(Map.get(params, "org_id"))
    }

    case Tenancy.create_group_claim(attrs) do
      {:ok, _claim} ->
        {:noreply,
         socket
         |> put_flash(:info, "Mapped #{OrgGroupClaim.normalize(attrs.claim_value)}.")
         |> load_group_claims()
         |> load_queue()}

      {:error, changeset} ->
        # Reload first: the row that owns a duplicate value may have been
        # added by another admin since this mount, and the message is only
        # useful if it can name its org.
        socket = load_group_claims(socket)

        {:noreply,
         put_flash(socket, :error, mapping_error_message(changeset, attrs, socket.assigns))}
    end
  end

  def handle_event("delete_group_mapping", %{"id" => id}, socket) do
    # Resolve off the already-loaded list rather than a fresh `Repo.get` —
    # an id from the DOM never reaches a query, so a stale or malformed one
    # is a no-op instead of a cast error.
    case Enum.find(socket.assigns.group_claims, &(&1.id == id)) do
      nil ->
        {:noreply,
         socket |> put_flash(:error, "That mapping is already gone.") |> load_group_claims()}

      claim ->
        case Tenancy.delete_group_claim(claim) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Removed the mapping for #{claim.claim_value}.")
             |> load_group_claims()
             |> load_queue()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not remove that mapping. Try again.")}
        end
    end
  end

  # Live-append: a fresh holding login arrived while this queue is open.
  # Prepend it (skip if already provisioned or already listed) and bump the
  # "new" badge — no reload.
  @impl true
  def handle_info({:external_admission_holding, payload}, socket) do
    with %{user_id: uid} when is_binary(uid) <- payload,
         %_{} = user <- Accounts.get_user(uid),
         false <- Tenancy.external_user?(user),
         false <- Enum.any?(socket.assigns.queue, &(&1.user_id == uid)) do
      # Build through `ExternalAdmission.build_row/2` + `attach_org_suggestions/1`
      # — the SAME two functions `awaiting_setup/0` ends in — so a live-appended
      # row is shape-identical to a reloaded one, group-claim suggestion
      # included. A suggestion that only shows up after a refresh is the
      # regression that costs; sharing the constructor is what prevents it
      # (task 019ff7ff stage 3).
      [row] =
        user
        |> ExternalAdmission.build_row(
          reason: Map.get(payload, :reason),
          last_seen_at: Map.get(payload, :at) || DateTime.utc_now(),
          suggested_org_id: Map.get(payload, :suggested_org_id),
          group_match: Map.get(payload, :group_match),
          group_values: Map.get(payload, :group_values)
        )
        |> List.wrap()
        |> ExternalAdmission.attach_org_suggestions()

      {:noreply,
       socket
       |> assign(:queue, [row | socket.assigns.queue])
       |> assign(:new_count, socket.assigns.new_count + 1)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Internals ──────────────────────────────────────────────────────────

  defp do_grant(socket, admin_user, target_user, params) do
    attrs = grant_attrs(target_user, params)

    case ExternalAdmission.recover(admin_user, target_user, attrs) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Granted access to #{display_name(target_user)}.")
         |> load_queue()}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not grant access. Check the target org and try again.")}
    end
  end

  # Append the selected channels to an already-provisioned external user
  # without going back through `recover/3`/`create_grant` (which would
  # collide on the per-email unique index). Idempotent participant inserts.
  defp add_channels(socket, target_user, params) do
    case grant_attrs(target_user, params).space_grants do
      [] ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Select at least one channel to add for #{display_name(target_user)}."
         )
         |> load_provisioned()}

      space_grants ->
        case ExternalGrants.add_space_participants(target_user, space_grants) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Added #{length(space_grants)} channel(s) for #{display_name(target_user)}."
             )
             |> load_provisioned()}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not add channels. Try again.")}
        end
    end
  end

  # Build the `create_grant/1` attrs from the compact form. The target
  # user's email is the grant identity; the checked channels each become a
  # `space_grants` entry (0..N — an empty selection is a valid org-only
  # grant); the DM checkbox allowlists the target org.
  defp grant_attrs(target_user, params) do
    org_id = Map.get(params, "target_org_id")
    space_ids = selected_space_ids(params)
    allow_dm? = Map.get(params, "allow_dm") in ["true", "on", true]

    %{
      email: target_user.email,
      oidc_sub: target_user.oidc_sub,
      target_org_id: org_id,
      space_grants: Enum.map(space_ids, &%{"space_id" => &1, "role" => "member"}),
      dm_allowlist_org_ids: if(allow_dm? and org_id, do: [org_id], else: [])
    }
  end

  # Checkbox inputs named `space_ids[]` arrive as a list under the
  # `"space_ids"` param key. Tolerate a legacy single `"space_id"`, drop
  # blanks, and dedup so a channel is granted at most once.
  defp selected_space_ids(params) do
    (List.wrap(Map.get(params, "space_ids")) ++ List.wrap(Map.get(params, "space_id")))
    |> Enum.map(&presence/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp load_group_claims(socket) do
    assign(socket, :group_claims, Tenancy.list_group_claims())
  end

  # A legible failure, and for the duplicate case a failure that NAMES the
  # org already holding the value — "has already been taken" alone sends an
  # admin hunting for a mapping they cannot see, and a second mapping for
  # the same value is exactly what makes the resolver answer `:ambiguous`
  # for everyone.
  defp mapping_error_message(changeset, attrs, assigns) do
    cond do
      taken?(changeset, :claim_value) ->
        value = OrgGroupClaim.normalize(attrs.claim_value)

        "\"#{value}\" is already mapped to #{owning_org_name(assigns, value)}. " <>
          "Remove that mapping first."

      blank?(changeset, :claim_value) ->
        "Enter a group value to map. A blank value would match every login."

      blank?(changeset, :org_id) ->
        "Choose the org this group value maps to."

      true ->
        "Could not save that mapping. Check the value and try again."
    end
  end

  defp owning_org_name(assigns, value) do
    case Enum.find(assigns.group_claims, &(&1.claim_value == value)) do
      %{org: %{name: name}} when is_binary(name) -> name
      _ -> "another org"
    end
  end

  defp taken?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  defp blank?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_msg, opts}} -> Keyword.get(opts, :validation) == :required
      _ -> false
    end)
  end

  defp load_queue(socket) do
    assign(socket, :queue, ExternalAdmission.awaiting_setup())
  end

  # Provisioned external users + the channels they're already in, for the
  # add-channels surface. `awaiting_setup/0` deliberately drops these rows,
  # so they need their own source.
  defp load_provisioned(socket) do
    provisioned =
      Enum.map(Tenancy.list_external_users(), fn user ->
        %{
          user: user,
          user_id: user.id,
          member_space_ids: Chat.list_member_space_ids(user.id, kind: "channel")
        }
      end)

    assign(socket, :provisioned, provisioned)
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(v) when is_binary(v), do: v

  # ── Template helpers ───────────────────────────────────────────────────

  @doc """
  Mobile-first, scale-ready channel picker for a grant/add-channels form.

  Built to stay usable with 40+ channels on a 375px viewport: a search box
  filters the list as you type, the list scrolls inside its own capped-height
  container (so the Grant button never gets pushed off-screen), and a live
  "N selected" badge keeps the current selection legible while browsing.

  Filtering is client-side (`ChannelPicker` hook), so a checked channel is
  never dropped by a search — filtered-out rows stay in the DOM (hidden) and
  their checked value still submits; checked rows also stay visible even when
  they don't match the query. `checked_ids` pre-checks channels; `disabled_ids`
  renders those as locked (already joined). Semantic DaisyUI token slots only
  (`exploring` brand — brand cyan `primary`, no hardcoded palette).
  """
  attr :id, :string, required: true
  attr :spaces, :list, required: true
  attr :checked_ids, :list, default: []
  attr :disabled_ids, :list, default: []

  def channel_checkboxes(assigns) do
    ~H"""
    <div id={"channel-picker-#{@id}"} phx-hook="ChannelPicker" data-role="channel-picker">
      <div class="mb-2 flex items-center gap-2">
        <div class="relative flex-1">
          <span class="hero-magnifying-glass pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-base-content/40">
          </span>
          <input
            type="text"
            data-role="channel-search"
            autocomplete="off"
            placeholder="Search channels…"
            aria-label="Search channels"
            class="input input-sm input-bordered h-11 w-full bg-base-100 pl-9"
          />
        </div>
        <span
          data-role="selected-count"
          class="badge badge-ghost badge-sm whitespace-nowrap"
          aria-live="polite"
        >
          0 selected
        </span>
      </div>

      <div
        class="max-h-72 overflow-y-auto rounded-lg border border-edge bg-base-100"
        data-role="channel-checklist"
      >
        <p
          :if={@spaces == []}
          class="px-3 py-3 text-xs text-base-content/50"
          data-role="channel-empty"
        >
          No channels available.
        </p>
        <p
          class="hidden px-3 py-3 text-xs text-base-content/50"
          data-role="channel-empty-filter"
        >
          No channels match your search.
        </p>
        <label
          :for={space <- @spaces}
          class="flex min-h-11 cursor-pointer items-center gap-3 border-b border-base-200 px-3 py-2 last:border-b-0 hover:bg-base-200"
          data-role="channel-option"
          data-space-id={space.id}
          data-channel-name={String.downcase(space.name)}
        >
          <input
            type="checkbox"
            name="space_ids[]"
            value={space.id}
            checked={space.id in @checked_ids}
            disabled={space.id in @disabled_ids}
            class="checkbox checkbox-sm checkbox-primary"
          />
          <span class="text-sm text-base-content">{space.name}</span>
          <span
            :if={space.id in @disabled_ids}
            class="badge badge-ghost badge-xs ml-auto"
          >
            joined
          </span>
        </label>
      </div>
    </div>
    """
  end

  @doc false
  def display_name(%{name: name}) when is_binary(name) and name != "", do: name
  def display_name(%{email: email}) when is_binary(email) and email != "", do: email
  def display_name(_), do: "Unknown user"

  @doc false
  def relative_time(nil), do: ""

  def relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%b %d")
    end
  end
end
