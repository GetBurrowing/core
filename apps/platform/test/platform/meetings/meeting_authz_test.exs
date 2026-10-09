defmodule Platform.Meetings.MeetingAuthzTest do
  @moduledoc """
  Pins `Platform.Meetings.fetch_meeting_for_user/2` — the org-scoped,
  viewer-aware replacement for the unscoped `get_meeting_by_slug/1` read that
  `/meetings/:slug` binds against.

  Two distinct things are asserted here:

    * **Authorization** — a viewer only resolves meetings belonging to an org
      they hold an `org_memberships` row in (root admins excepted, external
      users further narrowed).
    * **Ambiguity** — `meetings.slug` is unique per *project*, not globally, so
      a slug-only lookup can legitimately match more than one row. The function
      must report that rather than raise `Ecto.MultipleResultsError` or silently
      pick a row.
  """
  use Platform.DataCase, async: true

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # ── Fixtures ──────────────────────────────────────────────────────────────

  # `@example.com` so `Tenancy.derive_role_from_email/1` yields `:member` —
  # a `@acme.test` address would derive admin and bypass the very check
  # under test.
  defp user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{email: "authz-#{n}@example.com", name: "Authz #{n}", oidc_sub: "oidc-authz-#{n}"},
        overrides
      )

    %User{} |> User.changeset(attrs) |> Repo.insert!()
  end

  defp member!(user, org_id, role \\ "member") do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: role})
    |> Repo.insert!()

    user
  end

  defp meeting_in_org!(org_id, name) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Project #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
    meeting
  end

  # ── Allow ─────────────────────────────────────────────────────────────────

  describe "fetch_meeting_for_user/2 — entitled viewers" do
    test "a member of the meeting's org gets the meeting with :chat_space preloaded" do
      org_id = tenant_org_id("soylent")
      meeting = meeting_in_org!(org_id, "Kickoff")
      viewer = user!() |> member!(org_id)

      assert {:ok, fetched} = Meetings.fetch_meeting_for_user(viewer, meeting.slug)
      assert fetched.id == meeting.id
      assert %Chat.Space{id: space_id} = fetched.chat_space
      assert space_id == meeting.chat_space_id
    end

    test "an Acme root admin resolves a tenant-org meeting they hold no membership in" do
      org_id = tenant_org_id("wayne_tech")
      meeting = meeting_in_org!(org_id, "Root Admin Reach")
      admin = user!() |> member!(acme_org_id(), "admin")

      refute Tenancy.member_of?(admin, org_id)
      assert Tenancy.root_admin?(admin)

      assert {:ok, fetched} = Meetings.fetch_meeting_for_user(admin, meeting.slug)
      assert fetched.id == meeting.id
    end
  end

  # ── Deny ──────────────────────────────────────────────────────────────────

  describe "fetch_meeting_for_user/2 — unentitled viewers" do
    test "a non-member of the meeting's org gets :not_found" do
      meeting = meeting_in_org!(tenant_org_id("soylent"), "Private Sync")
      # Acme membership only, at member level — the shape every OIDC signup has.
      outsider = user!() |> member!(acme_org_id())

      refute Tenancy.root_admin?(outsider)
      assert {:error, :not_found} = Meetings.fetch_meeting_for_user(outsider, meeting.slug)
    end

    test "a nil user is never authorized" do
      meeting = meeting_in_org!(tenant_org_id("soylent"), "Anonymous Probe")

      assert {:error, :not_found} = Meetings.fetch_meeting_for_user(nil, meeting.slug)
      assert {:error, :not_found} = Meetings.fetch_meeting_for_user(%{}, meeting.slug)
    end

    test "an external member of the org is narrowed to meetings whose chat space they join" do
      org_id = tenant_org_id("soylent")
      meeting = meeting_in_org!(org_id, "Internal Only")
      external = user!()
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: external.id, org_id: org_id})

      # Org membership alone does not admit an external user.
      assert {:error, :not_found} = Meetings.fetch_meeting_for_user(external, meeting.slug)

      {:ok, _participant} =
        Chat.add_participant(meeting.chat_space_id, %{
          participant_type: "user",
          participant_id: external.id,
          joined_at: DateTime.utc_now()
        })

      assert {:ok, fetched} = Meetings.fetch_meeting_for_user(external, meeting.slug)
      assert fetched.id == meeting.id
    end
  end

  # ── Slug collisions across orgs ───────────────────────────────────────────

  describe "fetch_meeting_for_user/2 — slug is unique per project, not globally" do
    setup do
      soylent_id = tenant_org_id("soylent")
      wayne_tech_id = tenant_org_id("wayne_tech")

      soylent_meeting = meeting_in_org!(soylent_id, "Standup")
      wayne_tech_meeting = meeting_in_org!(wayne_tech_id, "Standup")

      # Same slug string, two rows, two orgs — legal under
      # unique_index(:meetings, [:project_id, :slug]).
      assert soylent_meeting.slug == wayne_tech_meeting.slug
      refute soylent_meeting.id == wayne_tech_meeting.id

      %{
        soylent_id: soylent_id,
        wayne_tech_id: wayne_tech_id,
        soylent_meeting: soylent_meeting,
        wayne_tech_meeting: wayne_tech_meeting,
        slug: soylent_meeting.slug
      }
    end

    test "a viewer in exactly one of the two orgs resolves that org's meeting", ctx do
      soylent_viewer = user!() |> member!(ctx.soylent_id)
      wayne_tech_viewer = user!() |> member!(ctx.wayne_tech_id)

      assert {:ok, a} = Meetings.fetch_meeting_for_user(soylent_viewer, ctx.slug)
      assert a.id == ctx.soylent_meeting.id

      assert {:ok, b} = Meetings.fetch_meeting_for_user(wayne_tech_viewer, ctx.slug)
      assert b.id == ctx.wayne_tech_meeting.id
    end

    test "a viewer entitled to both is told the link is ambiguous, not handed one at random",
         ctx do
      viewer =
        user!()
        |> member!(ctx.soylent_id)
        |> member!(ctx.wayne_tech_id)

      assert {:error, :ambiguous} = Meetings.fetch_meeting_for_user(viewer, ctx.slug)
    end

    test "a root admin entitled to both also gets :ambiguous rather than MultipleResultsError",
         ctx do
      admin = user!() |> member!(acme_org_id(), "admin")

      assert {:error, :ambiguous} = Meetings.fetch_meeting_for_user(admin, ctx.slug)
    end
  end
end
