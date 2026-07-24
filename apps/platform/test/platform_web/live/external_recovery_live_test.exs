defmodule PlatformWeb.ExternalRecoveryLiveTest do
  @moduledoc """
  Coverage for the admin recovery queue (rbac-external-users M3 stage 4,
  task 019f8837).

    * the queue lists a holding login and EXCLUDES an already-provisioned
      external user;
    * clicking Grant calls `recover/3`, materializes the grant, and the row
      drops on reload;
    * an `{:external_admission_holding, _}` broadcast live-appends a row +
      bumps the "new" badge without a reload;
    * a non-admin is halted by the `:ensure_admin` live_session hook.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.ExternalAdmission
  alias Platform.Accounts.ExternalAdmissionNotifier
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org
  alias Platform.Tenancy.OrgMembership
  alias Platform.Tenancy.PendingExternalGrant

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "recovery-#{n}@example.com",
          name: "Recovery #{n}",
          oidc_sub: "oidc-recovery-#{n}"
        },
        overrides
      )

    %User{} |> User.changeset(attrs) |> Repo.insert!()
  end

  defp create_org!(overrides \\ %{}) do
    n = System.unique_integer([:positive])
    # Only ONE root org may exist (orgs_single_root), so target orgs are
    # children of the Fabrikam root.
    fabrikam = Tenancy.get_org_by_slug!("fabrikam")

    attrs =
      Map.merge(
        %{name: "Target Org #{n}", slug: "target-org-#{n}", parent_org_id: fabrikam.id},
        overrides
      )

    %Org{} |> Org.changeset(attrs) |> Repo.insert!()
  end

  defp create_fabrikam_admin! do
    user = create_user!()
    fabrikam = Tenancy.get_org_by_slug!("fabrikam")
    create_membership!(user, fabrikam, "admin")
    user
  end

  defp create_membership!(user, org, role) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
    |> Repo.insert!()
  end

  # Seed the durable queue source: a persisted `holding` admission audit row.
  defp record_holding!(user) do
    {:ok, ev} =
      Platform.Audit.record(%{
        event_type: "platform.auth.external_admission",
        actor_type: "user",
        actor_id: user.id,
        action: "holding",
        metadata: %{"reason" => "awaiting_grant", "email" => user.email}
      })

    ev
  end

  defp authenticated_conn(conn, user) do
    Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})
  end

  defp reload_user(%User{id: id}), do: Repo.get(User, id)

  defp create_channel!(name) do
    n = System.unique_integer([:positive])
    {:ok, space} = Chat.create_space(%{name: name, slug: "chan-#{n}", kind: "channel"})
    space
  end

  defp participant_space_ids(user_id) do
    Participant
    |> where([p], p.participant_type == "user" and p.participant_id == ^user_id)
    |> select([p], p.space_id)
    |> Repo.all()
  end

  defp pending_grant_count(email) do
    Repo.aggregate(from(g in PendingExternalGrant, where: g.email == ^email), :count)
  end

  # ── Tests ────────────────────────────────────────────────────────────────

  describe "queue" do
    test "lists a holding login and excludes an already-provisioned external user", %{conn: conn} do
      admin = create_fabrikam_admin!()

      holding = create_user!(%{name: "Still Holding"})
      record_holding!(holding)

      # Provisioned external user: has an external membership + a holding
      # audit row, but must be excluded (already recovered).
      provisioned = create_user!(%{name: "Already In"})
      org = create_org!()
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: provisioned.id, org_id: org.id})
      record_holding!(provisioned)

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")

      assert has_element?(view, ~s([data-role=queue-row][data-user-id="#{holding.id}"]))
      refute has_element?(view, ~s([data-role=queue-row][data-user-id="#{provisioned.id}"]))
    end
  end

  describe "grant" do
    test "clicking Grant materializes the grant and drops the row on reload", %{conn: conn} do
      admin = create_fabrikam_admin!()
      target_org = create_org!()

      holding = create_user!(%{name: "Grant Me"})
      record_holding!(holding)

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")

      assert has_element?(view, ~s([data-role=queue-row][data-user-id="#{holding.id}"]))
      refute Tenancy.external_user?(reload_user(holding))

      view
      |> element(
        ~s([data-role=queue-row][data-user-id="#{holding.id}"] form[data-role=grant-form])
      )
      |> render_submit(%{"user_id" => holding.id, "target_org_id" => target_org.id})

      # Grant applied → user is now external → row drops off the queue.
      assert Tenancy.external_user?(reload_user(holding))
      refute has_element?(view, ~s([data-role=queue-row][data-user-id="#{holding.id}"]))
    end

    test "granting 2+ channels in one submit creates a participant row per channel", %{
      conn: conn
    } do
      admin = create_fabrikam_admin!()
      target_org = create_org!()
      chan_a = create_channel!("Orion")
      chan_b = create_channel!("Bug Reports")

      holding = create_user!(%{name: "Multi Grant"})
      record_holding!(holding)

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")

      view
      |> element(
        ~s([data-role=queue-row][data-user-id="#{holding.id}"] form[data-role=grant-form])
      )
      |> render_submit(%{
        "user_id" => holding.id,
        "target_org_id" => target_org.id,
        "space_ids" => [chan_a.id, chan_b.id]
      })

      # Both channels materialized — not just the first.
      assert Tenancy.external_user?(reload_user(holding))
      ids = participant_space_ids(holding.id)
      assert chan_a.id in ids
      assert chan_b.id in ids
      refute has_element?(view, ~s([data-role=queue-row][data-user-id="#{holding.id}"]))
    end

    test "granting with zero channels still provisions the org and adds no participants", %{
      conn: conn
    } do
      admin = create_fabrikam_admin!()
      target_org = create_org!()

      holding = create_user!(%{name: "Org Only"})
      record_holding!(holding)

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")

      view
      |> element(
        ~s([data-role=queue-row][data-user-id="#{holding.id}"] form[data-role=grant-form])
      )
      |> render_submit(%{"user_id" => holding.id, "target_org_id" => target_org.id})

      # Org-only grant is valid: external membership, no channel participants.
      assert Tenancy.external_user?(reload_user(holding))
      assert participant_space_ids(holding.id) == []
      refute has_element?(view, ~s([data-role=queue-row][data-user-id="#{holding.id}"]))
    end
  end

  describe "add channels to an already-provisioned user" do
    setup %{conn: conn} do
      admin = create_fabrikam_admin!()
      target_org = create_org!()
      chan_a = create_channel!("Orion")
      chan_b = create_channel!("Bug Reports")

      user = create_user!(%{name: "Add More"})

      {:ok, _result} =
        ExternalAdmission.recover(admin, user, %{
          email: user.email,
          oidc_sub: user.oidc_sub,
          target_org_id: target_org.id,
          space_grants: [%{"space_id" => chan_a.id, "role" => "member"}],
          dm_allowlist_org_ids: []
        })

      %{conn: conn, admin: admin, user: user, chan_a: chan_a, chan_b: chan_b}
    end

    test "adding a second channel appends a participant row and keeps the first", %{
      conn: conn,
      admin: admin,
      user: user,
      chan_a: chan_a,
      chan_b: chan_b
    } do
      assert Tenancy.external_user?(reload_user(user))
      assert participant_space_ids(user.id) == [chan_a.id]

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")

      # Provisioned users surface in their own add-channels section, not the queue.
      assert has_element?(view, ~s([data-role=provisioned-row][data-user-id="#{user.id}"]))
      refute has_element?(view, ~s([data-role=queue-row][data-user-id="#{user.id}"]))

      view
      |> element(
        ~s([data-role=provisioned-row][data-user-id="#{user.id}"] form[data-role=add-channels-form])
      )
      |> render_submit(%{"user_id" => user.id, "space_ids" => [chan_b.id]})

      ids = participant_space_ids(user.id)
      assert chan_a.id in ids
      assert chan_b.id in ids

      # No second pending-grant row — the append path avoids the email unique index.
      assert pending_grant_count(user.email) == 1
    end

    test "re-adding the same channel is idempotent", %{
      conn: conn,
      admin: admin,
      user: user,
      chan_b: chan_b
    } do
      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")

      form = fn ->
        view
        |> element(
          ~s([data-role=provisioned-row][data-user-id="#{user.id}"] form[data-role=add-channels-form])
        )
        |> render_submit(%{"user_id" => user.id, "space_ids" => [chan_b.id]})
      end

      form.()
      form.()

      count =
        Repo.aggregate(
          from(p in Participant,
            where: p.participant_id == ^user.id and p.space_id == ^chan_b.id
          ),
          :count
        )

      assert count == 1
      assert pending_grant_count(user.email) == 1
    end
  end

  describe "live append" do
    test "an external_admission_holding broadcast appends a row and bumps the badge", %{
      conn: conn
    } do
      admin = create_fabrikam_admin!()
      newcomer = create_user!(%{name: "Just Arrived"})

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")

      refute has_element?(view, ~s([data-role=queue-row][data-user-id="#{newcomer.id}"]))
      refute has_element?(view, "[data-role=new-login-badge]")

      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        ExternalAdmissionNotifier.admin_admissions_topic(),
        {:external_admission_holding,
         %{
           user_id: newcomer.id,
           email: newcomer.email,
           reason: :awaiting_grant,
           at: DateTime.utc_now()
         }}
      )

      # Force the LiveView to process the broadcast, then assert the append.
      _ = render(view)

      assert has_element?(view, ~s([data-role=queue-row][data-user-id="#{newcomer.id}"]))
      assert has_element?(view, "[data-role=new-login-badge]")
    end
  end

  describe "admin gate" do
    test "a non-admin member is redirected away", %{conn: conn} do
      user = create_user!()
      fabrikam = Tenancy.get_org_by_slug!("fabrikam")
      create_membership!(user, fabrikam, "member")

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn |> authenticated_conn(user) |> live("/admin/external-logins")
    end
  end
end
