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
  alias Platform.Tenancy.OrgGroupClaim
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
    # children of the Acme root.
    acme = Tenancy.get_org_by_slug!("acme")

    attrs =
      Map.merge(
        %{name: "Target Org #{n}", slug: "target-org-#{n}", parent_org_id: acme.id},
        overrides
      )

    %Org{} |> Org.changeset(attrs) |> Repo.insert!()
  end

  defp create_acme_admin! do
    user = create_user!()
    acme = Tenancy.get_org_by_slug!("acme")
    create_membership!(user, acme, "admin")
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
      admin = create_acme_admin!()

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
      admin = create_acme_admin!()
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
      admin = create_acme_admin!()
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
      admin = create_acme_admin!()
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
      admin = create_acme_admin!()
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
      admin = create_acme_admin!()
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

    # Task 019ff7ff stage 3. The regression this guards is a suggestion that
    # only appears after a reload: the two row-construction sites (audit
    # replay in `awaiting_setup/0`, notifier payload here) drifting apart.
    test "a live-appended row carries the same keys AND suggestion as a reloaded one", %{
      conn: conn
    } do
      admin = create_acme_admin!()
      org = create_org!()
      reloaded_user = create_user!(%{name: "Reloaded"})
      appended_user = create_user!(%{name: "Appended"})

      {:ok, _ev} =
        Platform.Audit.record(%{
          event_type: "platform.auth.external_admission",
          actor_type: "user",
          actor_id: reloaded_user.id,
          action: "holding",
          metadata: %{
            "reason" => "awaiting_grant",
            "email" => reloaded_user.email,
            "suggested_org_id" => org.id,
            "group_match" => "one"
          }
        })

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")

      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        ExternalAdmissionNotifier.admin_admissions_topic(),
        {:external_admission_holding,
         %{
           user_id: appended_user.id,
           email: appended_user.email,
           reason: :awaiting_grant,
           suggested_org_id: org.id,
           group_match: :one,
           at: DateTime.utc_now()
         }}
      )

      _ = render(view)

      queue = queue_assign(view)
      appended = Enum.find(queue, &(&1.user_id == appended_user.id))
      reloaded = Enum.find(queue, &(&1.user_id == reloaded_user.id))

      # Same key set — a key added to one construction site and not the other
      # fails right here.
      assert Map.keys(appended) == Map.keys(reloaded)

      # And the same resolved suggestion, without a reload.
      assert appended.suggested_org_id == org.id
      assert appended.group_match == :one
      assert appended.suggested_org.id == org.id
      assert appended.suggested_org.name == org.name
      assert reloaded.suggested_org_id == org.id
      assert reloaded.suggested_org.id == org.id
    end

    test "a live-appended row with a pre-stage-2 payload degrades to nil/:none" do
      # Guarded by the same shared constructor: an older notifier payload
      # (no suggestion keys at all) must not raise and must not invent one.
      user = create_user!(%{name: "Legacy Payload"})

      [row] =
        user
        |> ExternalAdmission.build_row(reason: :awaiting_grant, last_seen_at: DateTime.utc_now())
        |> List.wrap()
        |> ExternalAdmission.attach_org_suggestions()

      assert row.reason == "awaiting_grant"
      assert row.suggested_org_id == nil
      assert row.suggested_org == nil
      assert row.group_match == :none
    end

    test "a live-appended row whose suggested org was archived shows no suggestion", %{conn: conn} do
      admin = create_acme_admin!()
      org = create_org!()
      newcomer = create_user!(%{name: "Archived Suggestion"})

      {1, _} =
        Repo.update_all(
          from(o in Org, where: o.id == ^org.id),
          set: [archived_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")

      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        ExternalAdmissionNotifier.admin_admissions_topic(),
        {:external_admission_holding,
         %{
           user_id: newcomer.id,
           email: newcomer.email,
           reason: :awaiting_grant,
           suggested_org_id: org.id,
           group_match: :one,
           at: DateTime.utc_now()
         }}
      )

      _ = render(view)

      row = view |> queue_assign() |> Enum.find(&(&1.user_id == newcomer.id))

      assert row.suggested_org_id == nil
      assert row.suggested_org == nil
    end
  end

  # ── Stage 4: the suggestion is a suggestion ──────────────────────────────
  #
  # The trio below is the point: a one-match row alone would pass for an
  # implementation that always selects the first org. Zero-match and
  # two-match are what discriminate.
  describe "target-org pre-selection" do
    # Seed a holding audit row carrying stage 2's suggestion keys.
    defp record_holding_with_claim!(user, suggested_org_id, group_match) do
      metadata =
        %{"reason" => "awaiting_grant", "email" => user.email, "group_match" => group_match}
        |> then(fn m ->
          if suggested_org_id, do: Map.put(m, "suggested_org_id", suggested_org_id), else: m
        end)

      {:ok, ev} =
        Platform.Audit.record(%{
          event_type: "platform.auth.external_admission",
          actor_type: "user",
          actor_id: user.id,
          action: "holding",
          metadata: metadata
        })

      ev
    end

    defp row_html(view, user_id) do
      view
      |> element(~s([data-role=queue-row][data-user-id="#{user_id}"]))
      |> render()
    end

    # LazyHTML.query/2 returns a struct, which is never falsy — count nodes.
    defp count_nodes(html, selector) do
      html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
    end

    defp selected_org_ids(html) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s|[data-role=grant-org] option[selected]:not([value=""])|)
      |> LazyHTML.attribute("value")
    end

    test "a one-match row pre-selects exactly that org and labels it a suggestion", %{conn: conn} do
      admin = create_acme_admin!()
      org = create_org!()
      _other = create_org!()

      user = create_user!(%{name: "One Match"})
      record_holding_with_claim!(user, org.id, "one")

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")
      html = row_html(view, user.id)

      assert selected_org_ids(html) == [org.id]
      assert count_nodes(html, "[data-role=org-suggestion]") == 1
      assert count_nodes(html, "[data-role=org-ambiguous]") == 0
      # The placeholder exists but is NOT the selected option here.
      assert count_nodes(html, ~s([data-role=grant-org] option[value=""])) == 1
      assert count_nodes(html, ~s([data-role=grant-org] option[value=""][selected])) == 0
    end

    test "a zero-match row selects no org — the placeholder holds the slot", %{conn: conn} do
      admin = create_acme_admin!()
      _org_a = create_org!()
      _org_b = create_org!()

      user = create_user!(%{name: "No Match"})
      record_holding_with_claim!(user, nil, "none")

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")
      html = row_html(view, user.id)

      assert selected_org_ids(html) == []

      assert count_nodes(html, ~s([data-role=grant-org] option[value=""][selected][disabled])) ==
               1

      assert count_nodes(html, "[data-role=org-suggestion]") == 0
      assert count_nodes(html, "[data-role=org-ambiguous]") == 0
      # And an empty submit is still blocked client-side.
      assert count_nodes(html, "[data-role=grant-org][required]") == 1
    end

    test "a two-match row selects no org and says the claim was ambiguous", %{conn: conn} do
      admin = create_acme_admin!()
      _org_a = create_org!()
      _org_b = create_org!()

      user = create_user!(%{name: "Ambiguous Match"})
      record_holding_with_claim!(user, nil, "ambiguous")

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")
      html = row_html(view, user.id)

      assert selected_org_ids(html) == []
      assert count_nodes(html, ~s([data-role=grant-org] option[value=""][selected])) == 1
      assert count_nodes(html, "[data-role=org-ambiguous]") == 1
      assert count_nodes(html, "[data-role=org-suggestion]") == 0
    end

    test "submitting a DIFFERENT org than the suggestion grants the submitted one", %{conn: conn} do
      admin = create_acme_admin!()
      suggested = create_org!()
      chosen = create_org!()

      user = create_user!(%{name: "Admin Overrode"})
      record_holding_with_claim!(user, suggested.id, "one")

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")
      assert selected_org_ids(row_html(view, user.id)) == [suggested.id]

      view
      |> element(~s([data-role=queue-row][data-user-id="#{user.id}"] form[data-role=grant-form]))
      |> render_submit(%{"user_id" => user.id, "target_org_id" => chosen.id})

      assert Tenancy.external_user?(reload_user(user))
      assert [%OrgMembership{org_id: org_id, external: true}] = memberships(user.id)
      assert org_id == chosen.id
      refute org_id == suggested.id
    end

    test "an inferred grant into the INTERNAL root org is still external: true", %{conn: conn} do
      admin = create_acme_admin!()
      acme = Tenancy.get_org_by_slug!("acme")

      user = create_user!(%{name: "Root Org Target"})
      record_holding_with_claim!(user, acme.id, "one")

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")
      assert selected_org_ids(row_html(view, user.id)) == [acme.id]

      view
      |> element(~s([data-role=queue-row][data-user-id="#{user.id}"] form[data-role=grant-form]))
      |> render_submit(%{"user_id" => user.id, "target_org_id" => acme.id})

      # The whole task exists to protect this: a mapped internal-looking group
      # must not mint an `external: false` membership.
      assert [%OrgMembership{org_id: org_id, external: true}] = memberships(user.id)
      assert org_id == acme.id
      assert Tenancy.external_user?(reload_user(user))
    end

    test "submitting an empty target org creates no membership", %{conn: conn} do
      admin = create_acme_admin!()
      _org = create_org!()

      user = create_user!(%{name: "Empty Submit"})
      record_holding_with_claim!(user, nil, "none")

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")

      view
      |> element(~s([data-role=queue-row][data-user-id="#{user.id}"] form[data-role=grant-form]))
      |> render_submit(%{"user_id" => user.id, "target_org_id" => ""})

      assert memberships(user.id) == []
      refute Tenancy.external_user?(reload_user(user))
      # Still in the queue, awaiting a real choice.
      assert has_element?(view, ~s([data-role=queue-row][data-user-id="#{user.id}"]))
    end

    defp memberships(user_id) do
      OrgMembership |> where([m], m.user_id == ^user_id) |> Repo.all()
    end
  end

  # The queue rows are backend state stage 4 renders; read them off the
  # socket rather than the markup, which does not show them yet.
  defp queue_assign(view), do: :sys.get_state(view.pid).socket.assigns.queue

  # ── Stage 5: the group-claim mapping editor ──────────────────────────────
  #
  # Every query below COUNTS NODES: LazyHTML.query/2 returns a struct, which
  # is never falsy, so `assert LazyHTML.query(...)` would pass on an empty
  # result.
  describe "group-claim mapping editor" do
    defp claim_count, do: Repo.aggregate(OrgGroupClaim, :count)

    defp nodes(html, selector) do
      html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
    end

    defp map_group!(value, org) do
      {:ok, claim} = Tenancy.create_group_claim(%{claim_value: value, org_id: org.id})
      claim
    end

    defp submit_mapping(view, params) do
      view |> element(~s([data-role=group-mapping-form])) |> render_submit(params)
    end

    test "adding a mapping renders a new row and persists it", %{conn: conn} do
      admin = create_acme_admin!()
      org = create_org!(%{name: "Northwind Supply", slug: "northwind-supply"})

      {:ok, view, html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")
      assert nodes(html, "[data-role=group-mapping-row]") == 0
      assert nodes(html, "[data-role=group-mapping-section]") == 1

      html = submit_mapping(view, %{"claim_value" => "Clients-Northwind", "org_id" => org.id})

      assert nodes(html, "[data-role=group-mapping-row]") == 1
      assert html =~ "clients-northwind"
      assert html =~ "Northwind Supply"

      # Persisted, normalized, and pointing at the submitted org.
      assert [claim] = Tenancy.list_group_claims()
      assert claim.claim_value == "clients-northwind"
      assert claim.org_id == org.id

      # And it is a SUGGESTION source only: no membership was written.
      assert Repo.aggregate(from(m in OrgMembership, where: m.external == true), :count) == 0
    end

    test "a blank claim value is rejected and nothing is inserted", %{conn: conn} do
      admin = create_acme_admin!()
      org = create_org!()

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")
      before = claim_count()

      # Whitespace-only: the changeset trims first, so this is the blank case.
      html = submit_mapping(view, %{"claim_value" => "   ", "org_id" => org.id})

      assert html =~ "Enter a group value to map"
      assert nodes(html, "[data-role=group-mapping-row]") == 0
      assert claim_count() == before
    end

    test "a duplicate claim value is rejected, names the owning org, and creates no second row",
         %{conn: conn} do
      admin = create_acme_admin!()
      owner = create_org!(%{name: "Northwind Supply", slug: "northwind-supply"})
      other = create_org!(%{name: "Contoso Freight", slug: "contoso-freight"})
      map_group!("clients-northwind", owner)

      {:ok, view, html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")
      assert nodes(html, "[data-role=group-mapping-row]") == 1

      # Different case, same value after normalization — the collision the
      # unique index exists for.
      html = submit_mapping(view, %{"claim_value" => "Clients-Northwind", "org_id" => other.id})

      assert html =~ "already mapped to Northwind Supply"
      # The error names the org that HOLDS it, not the one just submitted.
      refute html =~ "already mapped to Contoso Freight"
      assert nodes(html, "[data-role=group-mapping-row]") == 1
      assert claim_count() == 1
      assert [%{org_id: org_id}] = Tenancy.list_group_claims()
      assert org_id == owner.id
    end

    test "deleting a mapping removes it AND a later holding login no longer pre-selects",
         %{conn: conn} do
      admin = create_acme_admin!()
      org = create_org!(%{name: "Northwind Supply", slug: "northwind-supply"})
      claim = map_group!("clients-northwind", org)

      # Direction control: WHILE mapped, a holding login resolves to the org.
      before_delete = admit_external!("clients-northwind")
      assert before_delete.suggested_org_id == org.id
      assert before_delete.group_match == :one

      {:ok, view, html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")
      assert nodes(html, "[data-role=group-mapping-row]") == 1

      html =
        view
        |> element(
          ~s([data-role=group-mapping-row][data-claim-id="#{claim.id}"] ) <>
            ~s([data-role=group-mapping-delete])
        )
        |> render_click()

      assert nodes(html, "[data-role=group-mapping-row]") == 0
      assert claim_count() == 0

      # A SUBSEQUENT login carrying the same group now pre-selects nothing.
      after_delete = admit_external!("clients-northwind")
      assert after_delete.suggested_org_id == nil
      assert after_delete.group_match == :none
    end

    test "an unmapped holding row shows the values it carried, and says so when it carried none",
         %{conn: conn} do
      admin = create_acme_admin!()

      carried = create_user!(%{name: "Carried Groups"})
      record_holding_with_groups!(carried, ["clients-northwind", "everyone"])

      none = create_user!(%{name: "Carried Nothing"})
      record_holding_with_groups!(none, [])

      legacy = create_user!(%{name: "Legacy Row"})
      record_holding!(legacy)

      {:ok, view, _html} = conn |> authenticated_conn(admin) |> live("/admin/external-logins")

      carried_html = row_html(view, carried.id)
      assert nodes(carried_html, "[data-role=unmapped-group-value]") == 2
      assert carried_html =~ "clients-northwind"
      assert nodes(carried_html, "[data-role=unmapped-groups-unknown]") == 0
      assert nodes(carried_html, "[data-role=unmapped-groups-empty]") == 0

      none_html = row_html(view, none.id)
      assert nodes(none_html, "[data-role=unmapped-group-value]") == 0
      assert nodes(none_html, "[data-role=unmapped-groups-empty]") == 1
      assert nodes(none_html, "[data-role=unmapped-groups-unknown]") == 0

      # A pre-stage-5 row must NOT render as "carried no groups".
      legacy_html = row_html(view, legacy.id)
      assert nodes(legacy_html, "[data-role=unmapped-groups-unknown]") == 1
      assert nodes(legacy_html, "[data-role=unmapped-groups-empty]") == 0
      assert nodes(legacy_html, "[data-role=unmapped-group-value]") == 0
    end

    test "a non-admin is halted on mount, so no mapping handler is reachable", %{conn: conn} do
      member = create_user!()
      acme = Tenancy.get_org_by_slug!("acme")
      create_membership!(member, acme, "member")
      org = create_org!()
      before = claim_count()

      conn = authenticated_conn(conn, member)

      # 1. The mount — static AND connected — is redirected by the inherited
      #    `{PlatformWeb.LiveAuth, :ensure_admin}` hook.
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/admin/external-logins")

      # 2. The handler. `render_submit/2` needs a live view; a non-admin never
      #    gets one, so the write has no transport. Prove the halt happens at
      #    the same hook the connected mount runs (that is the ONLY channel a
      #    handle_event can arrive through) rather than only asserting the
      #    static redirect above.
      socket = %Phoenix.LiveView.Socket{
        assigns: %{root_admin?: false, flash: %{}, __changed__: %{}},
        private: %{
          connect_info: %{},
          lifecycle: %Phoenix.LiveView.Lifecycle{},
          live_temp: %{}
        }
      }

      assert {:halt, halted} =
               PlatformWeb.LiveAuth.on_mount(:ensure_admin, %{}, %{}, socket)

      # No assigns for the editor were ever built, so there is no socket a
      # "add_group_mapping" event could be routed to.
      refute Map.has_key?(halted.assigns, :group_claims)
      refute Map.has_key?(halted.assigns, :orgs)

      # And an admin CAN reach it — the gate is what differs, not the route.
      admin_conn = authenticated_conn(build_conn(), create_acme_admin!())
      {:ok, view, _html} = live(admin_conn, "/admin/external-logins")
      submit_mapping(view, %{"claim_value" => "clients-contoso", "org_id" => org.id})

      assert claim_count() == before + 1
    end

    # A holding audit row carrying stage 5's `external_groups` key.
    defp record_holding_with_groups!(user, groups) do
      {:ok, ev} =
        Platform.Audit.record(%{
          event_type: "platform.auth.external_admission",
          actor_type: "user",
          actor_id: user.id,
          action: "holding",
          metadata: %{
            "reason" => "awaiting_grant",
            "email" => user.email,
            "group_match" => "none",
            "external_groups" => groups
          }
        })

      ev
    end

    # Drive a REAL external login through admission so the assertion is about
    # what a future login resolves to, not about the resolver in isolation.
    defp admit_external!(group) do
      n = System.unique_integer([:positive])

      ExternalAdmission.admit(%{
        sub: "oidc-mapping-#{n}",
        email: "mapping-#{n}@example.com",
        name: "Mapping Probe #{n}",
        external_claim?: true,
        external_groups: [group]
      })
    end
  end

  describe "admin gate" do
    test "a non-admin member is redirected away", %{conn: conn} do
      user = create_user!()
      acme = Tenancy.get_org_by_slug!("acme")
      create_membership!(user, acme, "member")

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn |> authenticated_conn(user) |> live("/admin/external-logins")
    end
  end
end
