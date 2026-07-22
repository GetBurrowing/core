defmodule Platform.Accounts.ExternalAdmissionNotifierTest do
  @moduledoc """
  Coverage for `Platform.Accounts.ExternalAdmissionNotifier` (rbac-external-users
  M3 stage 3, task 019f8837) — the telemetry→admin bridge on ungranted
  (holding) external logins.

    * a `"holding"` event broadcasts `{:external_admission_holding, _}` on
      `admin_admissions_topic/0`;
    * a Fabrikam root-org admin is resolved as a recipient and the notification
      seam (`fan_out_to_humans/3`) is invoked with the `/admin/external-logins`
      url;
    * `"full"` / `"recovered"` produce NO admin broadcast/push;
    * the holding event persists an `Audit.Event` (the durable queue source);
    * a malformed metadata map never raises the handler (telemetry safety).
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.ExternalAdmissionNotifier
  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @event [:platform, :auth, :external_admission]

  defmodule Recorder do
    @moduledoc "Test double for `Platform.Notifications` — records fan-outs."
    def install(pid \\ self()), do: :persistent_term.put({__MODULE__, :owner}, pid)

    def fan_out_to_humans(participant_ids, payload, opts \\ []) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, {:notif, participant_ids, payload, opts})
      end

      :ok
    end
  end

  setup do
    # The handler is attached at app boot; ensure it's live for the test.
    ExternalAdmissionNotifier.attach()

    Application.put_env(:platform, :notifications_module, Recorder)
    Recorder.install(self())

    on_exit(fn -> Application.delete_env(:platform, :notifications_module) end)

    :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "notifier-#{n}@example.com",
          name: "Notifier #{n}",
          oidc_sub: "oidc-notifier-#{n}"
        },
        overrides
      )

    %User{} |> User.changeset(attrs) |> Repo.insert!()
  end

  defp create_fabrikam_admin! do
    user = create_user!()
    fabrikam = Tenancy.get_org_by_slug!("fabrikam")

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: fabrikam.id, role: "admin"})
    |> Repo.insert!()

    user
  end

  defp emit(action, metadata) do
    :telemetry.execute(
      @event,
      %{system_time: System.system_time()},
      Map.put(metadata, :action, action)
    )
  end

  # ── Tests ────────────────────────────────────────────────────────────────

  test "a holding event broadcasts on the admin admissions topic" do
    user = create_user!()
    Phoenix.PubSub.subscribe(Platform.PubSub, ExternalAdmissionNotifier.admin_admissions_topic())

    emit("holding", %{
      reason: :awaiting_grant,
      email: user.email,
      actor_id: user.id,
      external?: true
    })

    assert_receive {:external_admission_holding, payload}
    assert payload.user_id == user.id
    assert payload.email == user.email
  end

  test "a Fabrikam admin is resolved and the notification seam is invoked" do
    admin = create_fabrikam_admin!()
    user = create_user!()

    emit("holding", %{
      reason: :awaiting_grant,
      email: user.email,
      actor_id: user.id,
      external?: true
    })

    assert_receive {:notif, recipients, payload, _opts}
    assert admin.id in recipients
    assert payload.url == "/admin/external-logins"
    assert payload.title =~ "awaiting setup"
    assert payload.body =~ user.email
  end

  test "full and recovered actions produce no admin broadcast or push" do
    admin = create_fabrikam_admin!()
    _ = admin
    user = create_user!()
    Phoenix.PubSub.subscribe(Platform.PubSub, ExternalAdmissionNotifier.admin_admissions_topic())

    emit("full", %{reason: nil, email: user.email, actor_id: user.id, external?: false})
    emit("recovered", %{reason: nil, email: user.email, actor_id: user.id, external?: true})

    refute_receive {:external_admission_holding, _}, 200
    refute_receive {:notif, _, _, _}, 200
  end

  test "a holding event persists an Audit.Event (durable queue source)" do
    user = create_user!()

    emit("holding", %{
      reason: :awaiting_grant,
      email: user.email,
      actor_id: user.id,
      external?: true
    })

    rows =
      Platform.Audit.list(event_type: "platform.auth.external_admission", actor_id: user.id)

    assert Enum.any?(rows, fn ev -> ev.action == "holding" and ev.actor_id == user.id end)
  end

  test "a malformed metadata map does not raise the handler" do
    Phoenix.PubSub.subscribe(Platform.PubSub, ExternalAdmissionNotifier.admin_admissions_topic())

    # No email / reason / actor_id keys — the handler must tolerate it.
    emit("holding", %{})

    assert_receive {:external_admission_holding, _payload}
  end
end
