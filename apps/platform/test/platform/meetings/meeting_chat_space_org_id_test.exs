defmodule Platform.Meetings.MeetingChatSpaceOrgIdTest do
  @moduledoc """
  Task `019fcfdd` — the tenancy of the chat space `Meetings.create_meeting/1`
  mints alongside every meeting.

  ## What stage 1 pinned and stage 2 fixed

  The attrs literal handed to `Chat.create_space/1` inside `create_meeting/1`
  had four keys and no `:org_id`. It did not pass nil, it OMITTED the key, so
  every `kind: "meeting"` chat space ever created carried `org_id IS NULL` —
  including the row `invite_external_user/3` seats participants into.

  Stage 2 wired the module's own `resolve_meeting_org_id/1` and
  `maybe_put_org_id/2` — the pair `create_guest_chat_space/2` already used —
  into that call site. Both are `defp` in the same module, so nothing was
  promoted to public API. The first test below is stage 1's red test with its
  `:pending_fix` tag retired.

  ## Why every assertion here reads a COLUMN and none reads a return value

  `PlatformWeb.Plugs.ExternalUserScope.resolve_space/2` has a third resolution
  step, `system_prefix_fallback/1`, that does an UNSCOPED slug lookup —
  `Chat.get_space_by_slug(slug, [])` — for any slug matching
  `Chat.reserved_slug_prefix?/1` (`meeting-`, `task-exec-`, `dm-`, `group-`).
  `ChatLive.system_prefix_fallback/1` mirrors it.

  So resolving a meeting chat space SUCCEEDS whether or not the row carries an
  `org_id`. Any test phrased "an invited member can reach the meeting chat" is
  green before the fix and green after it: it proves the lookup TOLERATES a nil
  org, never that the row is scoped to the right tenant. Tolerance is not
  correctness, and a test that cannot fail is not evidence.

  `the reserved-prefix fallback is org-blind` below is the witness for that
  claim. It builds its space directly via `Chat.create_space/1` with an
  explicit `org_id: nil` rather than through `create_meeting/1`, so it keeps
  holding after the fix — it is about the FALLBACK, not the meeting write path.
  That fallback stays load-bearing for historical nil rows until the stage 3
  backfill lands, and permanently for the kinds that are cross-org by design.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  # ── Fixtures ──────────────────────────────────────────────────────────────

  # `Tasks.create_project/1` fills `:org_id` from the seeded root org when the
  # caller passes none (`Tasks.default_org_id/1`). Every test below asserts
  # that org actually resolved before drawing any conclusion from it — a nil
  # project org would make "the space org matches the project org" true by
  # nil == nil, which is the same vacuity in a different costume.
  defp project_with_org(attrs \\ %{}) do
    {:ok, project} =
      Tasks.create_project(
        Map.merge(
          %{name: "Org Scoping Project #{System.unique_integer([:positive])}"},
          attrs
        )
      )

    refute is_nil(project.org_id),
           "fixture is vacuous: the project resolved no org_id, so a nil space " <>
             "org would compare equal to it and every assertion below would pass " <>
             "for the wrong reason"

    project
  end

  # A tenant org that is NOT the seeded default `Tasks.default_org_id/1` hands
  # out. Without one, "the space carries the project's org" and "the space
  # carries a hardcoded default org" are the same assertion.
  defp non_default_org! do
    n = System.unique_integer([:positive])
    root = Tenancy.get_org_by_slug("acme")

    {:ok, org} =
      %Org{}
      |> Org.changeset(%{
        name: "Meeting Scoping Org #{n}",
        slug: "meetingscoping#{n}",
        parent_org_id: root && root.id
      })
      |> Repo.insert()

    org
  end

  defp meeting_for(project) do
    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Org Scoping Meeting #{System.unique_integer([:positive])}"
      })

    meeting
  end

  # Read `org_id` straight off the row rather than off the struct
  # `create_space/1` returned, so the assertion is about what is PERSISTED.
  defp persisted_org_id(space_id) do
    Repo.one!(from(s in Chat.Space, where: s.id == ^space_id, select: s.org_id))
  end

  # ── The fix ───────────────────────────────────────────────────────────────

  describe "Meetings.create_meeting/1 — chat space tenancy" do
    test "create_meeting/1 stamps the project's org_id onto the meeting chat space" do
      project = project_with_org()
      meeting = meeting_for(project)

      space = Chat.get_space(meeting.chat_space_id)

      # Guard the subject: if the kind or slug prefix ever changes, the org
      # below would be describing some other row than the one the meeting
      # binds and the invite path seats participants into.
      assert space.kind == "meeting"
      assert String.starts_with?(space.slug, "meeting-")
      assert space.id == meeting.chat_space_id

      assert persisted_org_id(meeting.chat_space_id) == project.org_id
    end

    test "the org is read from the meeting's own project, not from a seeded default" do
      # The anti-vacuity control for the test above. `Tasks.default_org_id/1`
      # stamps the root org onto any project created without an explicit one,
      # so a fix that wrote a CONSTANT org — or that resolved through anything
      # other than this meeting's project — would satisfy the previous test
      # and fail this one.
      org = non_default_org!()
      project = project_with_org(%{org_id: org.id})
      assert project.org_id == org.id

      default_org = Tenancy.get_org_by_slug("acme")

      refute is_nil(default_org),
             "fixture is vacuous: without the seeded root org there is no " <>
               "default for this test to distinguish itself from"

      refute org.id == default_org.id

      meeting = meeting_for(project)

      assert persisted_org_id(meeting.chat_space_id) == org.id
      refute persisted_org_id(meeting.chat_space_id) == default_org.id
    end
  end

  # ── The degraded path: an org that does not resolve must not break creation ─

  describe "an unresolvable org degrades rather than failing" do
    test "the key is dropped, the space insert still succeeds, and no new failure mode appears" do
      # `maybe_put_org_id(attrs, nil)` DROPS the key instead of writing an
      # explicit nil, so `Chat.create_space/1` sees exactly the attrs it saw
      # before this stage. A nil-org space is degraded; a meeting that cannot
      # be created is broken.
      #
      # Reachability note, because it bounds what this test can claim: a
      # project row with a NULL `org_id` CANNOT exist — `projects.org_id` is
      # NOT NULL at the database level (migration
      # `20260618181114_adr_0042_org_project_topology.exs`) and
      # `Project.changeset/2` carries `validate_required([:name, :org_id])`.
      # And `create_meeting/1` rejects a nil `project_id` at `require_present/2`
      # before any of this runs. So the ONLY shape that reaches
      # `resolve_meeting_org_id/1`'s nil answer from here is a well-formed
      # project id with no row behind it, which is what this builds.
      orphan_project_id = Platform.Types.UUIDv7.generate()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Meetings.create_meeting(%{
                 project_id: orphan_project_id,
                 name: "Orphan Project Meeting #{System.unique_integer([:positive])}"
               })

      # The space was minted before the meeting insert rolled the transaction
      # back — proof that dropping the key left `create_space/1` happy. If the
      # helper had written an explicit nil into a column that later gains a
      # constraint, or if the resolver had raised, there would be no
      # `chat_space_id` change to find here.
      assert is_binary(changeset.changes[:chat_space_id])

      # The failure is the meetings→projects foreign key and nothing else.
      # Any org-shaped error here would mean this stage introduced one.
      assert [project_id: {"does not exist", _}] = changeset.errors
    end
  end

  # ── Why the obvious test would have proved nothing ────────────────────────

  describe "the reserved-prefix fallback is org-blind" do
    test "a meeting- slug resolves unscoped, so reachability cannot witness the org" do
      # This is the vacuity trap, pinned.
      project = project_with_org()
      slug = "meeting-#{Platform.Types.UUIDv7.generate()}"

      {:ok, space} =
        Chat.create_space(%{
          name: "Fallback Witness",
          slug: slug,
          kind: "meeting",
          org_id: nil,
          metadata: %{"project_id" => project.id}
        })

      assert is_nil(persisted_org_id(space.id))

      # Step 1 of resolution — the org-scoped lookup — structurally cannot
      # match a NULL column, so it misses.
      assert is_nil(Chat.get_space_by_slug(slug, org_id: project.org_id))

      # Step 3 — the reserved-prefix fallback — hits anyway.
      assert Chat.reserved_slug_prefix?(slug)
      assert %Chat.Space{id: found_id} = Chat.get_space_by_slug(slug, [])
      assert found_id == space.id
    end
  end
end
