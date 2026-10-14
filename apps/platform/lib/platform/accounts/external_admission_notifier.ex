defmodule Platform.Accounts.ExternalAdmissionNotifier do
  @moduledoc """
  Bridges the `[:platform, :auth, :external_admission]` telemetry signal to
  root-org admins (rbac-external-users M3 stage 3, task 019f8837).

  M2's `ExternalAdmission` emits this event on EVERY login with metadata
  `action` (`"full"` / `"holding"` / `"recovered"`), `reason`, `email`,
  `actor_id`, `external?`. This handler consumes ONLY the `"holding"` case —
  an ungranted external user just black-holed — and does two things:

    1. Broadcasts `{:external_admission_holding, %{user_id:, email:, reason:,
       suggested_org_id:, group_match:, group_values:, at:}}` (the last
       three from task 019ff7ff stages 2 and 5) on `admin_admissions_topic/0` so any OPEN M3 stage-4 recovery
       surface live-appends the row + increments its "new" badge without a
       reload.
    2. Push-notifies root-org admins through the existing
       `Platform.Notifications.fan_out_to_humans/3` seam with an
       external-SAFE payload (title / body naming the email+reason, url
       `/admin/external-logins`), exactly as `MeetingNotifier` fans out.

  `"full"` / `"recovered"` need no admin action and are ignored.

  ## Attach shape

  Mirrors `Platform.Audit.TelemetryHandler`: a single `attach/0` wired from
  `Application.start/2`, and a `handle_event/4` that NEVER raises (telemetry
  detaches raising handlers). It runs ALONGSIDE the audit handler, which
  persists the same event as the durable queue row — this notifier only
  fans out; it does not persist.

  ## Test injection

  The notifications target is resolved at runtime via
  `Application.get_env(:platform, :notifications_module, Platform.Notifications)`
  so tests swap in a recorder per-case (same idiom as `MeetingNotifier`).
  """

  import Ecto.Query

  require Logger

  alias Platform.Repo
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership

  @handler_id "external-admission-notifier"
  @event [:platform, :auth, :external_admission]

  @doc """
  PubSub topic the M3 stage-4 recovery surface subscribes to for live
  "new holding login" appends. Single source of truth — stage 4 calls the
  SAME function.
  """
  @spec admin_admissions_topic() :: String.t()
  def admin_admissions_topic, do: "external_admissions:admin"

  @doc "Attach the handler. Idempotent — a duplicate attach is a no-op."
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, %{}) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detach the handler (useful in tests)."
  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event(@event, _measurements, %{action: "holding"} = metadata, _config) do
    payload = %{
      user_id: Map.get(metadata, :actor_id),
      email: Map.get(metadata, :email),
      reason: Map.get(metadata, :reason),
      # Task 019ff7ff stage 2 — the group-claim suggestion, mirrored so the
      # live-appended queue row carries it without a reload. `nil` /
      # `:none` are the honest values when nothing resolved.
      suggested_org_id: Map.get(metadata, :suggested_org_id),
      group_match: Map.get(metadata, :group_match, :none),
      # Task 019ff7ff stage 5 — the group values this login carried, so a
      # live-appended unmapped row can show them. Absent (nil) means the
      # emitter did not record them, which the admin surface reports as
      # "not recorded" rather than as an empty list.
      group_values: Map.get(metadata, :external_groups),
      at: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      admin_admissions_topic(),
      {:external_admission_holding, payload}
    )

    notify_admins(payload)
    :ok
  rescue
    # Telemetry detaches handlers that raise — never let that happen, even
    # on a malformed metadata map or a transient Repo error.
    error ->
      Logger.error(
        "[ExternalAdmissionNotifier] handler crashed: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  # Ignore `"full"` / `"recovered"` (no admin action needed) and any other
  # shape. Total handle_event/4 — telemetry never sees a crash.
  def handle_event(@event, _measurements, _metadata, _config), do: :ok

  # -- internals --

  defp notify_admins(payload) do
    recipients = root_admin_user_ids()

    notif_payload = %{
      title: "External login awaiting setup",
      body: notify_body(payload),
      url: "/admin/external-logins"
    }

    notifications_module().fan_out_to_humans(recipients, notif_payload)
    :ok
  end

  defp notify_body(%{email: email, reason: reason}) do
    who = if is_binary(email) and email != "", do: email, else: "An external user"
    "#{who} signed in but has no access yet#{reason_suffix(reason)}. Grant them to let them in."
  end

  defp reason_suffix(nil), do: ""
  defp reason_suffix(reason), do: " (#{reason})"

  # Root-org admins: `org_memberships.role == "admin"` joined to an org with
  # NO parent (the root org). Mirrors `Platform.Tenancy.root_admin?/1`'s
  # predicate, selecting the distinct recipient user ids instead of a
  # boolean.
  defp root_admin_user_ids do
    from(m in OrgMembership,
      join: o in Org,
      on: o.id == m.org_id,
      where: m.role == "admin" and is_nil(o.parent_org_id),
      distinct: true,
      select: m.user_id
    )
    |> Repo.all()
  end

  defp notifications_module do
    Application.get_env(:platform, :notifications_module, Platform.Notifications)
  end
end
