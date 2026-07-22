defmodule PlatformWeb.ExternalRecoveryLive do
  @moduledoc """
  External Recovery — the Fabrikam-admin surface listing external logins still
  awaiting setup, with a one-click Grant that live-applies to the waiting
  session (rbac-external-users M3 stage 4, task 019f8837).

  This is the ADMIN half of Rowan's live-recovery centerpiece: an external
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

  Fabrikam-only gate is inherited from the `:admin` `live_session`
  (`{PlatformWeb.LiveAuth, :ensure_admin}`).
  """
  use PlatformWeb, :live_view

  alias Platform.Accounts
  alias Platform.Accounts.ExternalAdmission
  alias Platform.Accounts.ExternalAdmissionNotifier
  alias Platform.Chat
  alias Platform.Tenancy

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
        # Double-grant race guard: if the user was already provisioned (a
        # concurrent admin won, or the queue row is stale), don't re-create a
        # grant — `create_grant/1` is a plain insert and would collide on the
        # per-email unique index. Just refresh; the row drops off.
        if Tenancy.external_user?(target_user) do
          {:noreply,
           socket
           |> put_flash(:info, "#{display_name(target_user)} was already granted access.")
           |> load_queue()}
        else
          do_grant(socket, admin_user, target_user, params)
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
      row = %{
        user: user,
        user_id: uid,
        email: user.email,
        reason: to_string_reason(Map.get(payload, :reason)),
        last_seen_at: Map.get(payload, :at) || DateTime.utc_now()
      }

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

  # Build the `create_grant/1` attrs from the compact form. The target
  # user's email is the grant identity; the optional channel becomes a
  # single `space_grants` entry; the DM checkbox allowlists the target org.
  defp grant_attrs(target_user, params) do
    org_id = Map.get(params, "target_org_id")
    space_id = presence(Map.get(params, "space_id"))
    allow_dm? = Map.get(params, "allow_dm") in ["true", "on", true]

    %{
      email: target_user.email,
      oidc_sub: target_user.oidc_sub,
      target_org_id: org_id,
      space_grants: if(space_id, do: [%{"space_id" => space_id, "role" => "member"}], else: []),
      dm_allowlist_org_ids: if(allow_dm? and org_id, do: [org_id], else: [])
    }
  end

  defp load_queue(socket) do
    assign(socket, :queue, ExternalAdmission.awaiting_setup())
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(v) when is_binary(v), do: v

  defp to_string_reason(nil), do: nil
  defp to_string_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(_), do: nil

  # ── Template helpers ───────────────────────────────────────────────────

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
