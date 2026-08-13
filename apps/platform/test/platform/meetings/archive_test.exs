defmodule Platform.Meetings.ArchiveTest do
  @moduledoc """
  Tests for `Platform.Meetings.Archive` (task `019fb954-c848`).

  Two of these tests have an obvious form that cannot fail, so the shape they
  are written in is load-bearing:

    * **Relevance over recency.** Phrased as "a matching meeting ranks above a
      more recent one that does not match", the assertion holds under *any*
      ordering — the non-matching meeting is in `:others` by construction, so
      pure recency passes it. The fixture below therefore puts **both**
      meetings in `:matches` and makes them differ on age and weight in
      **opposite** directions: the older meeting's hit is a canvas title
      (weight `B`), the newer meeting's is a transcript segment (weight `D`).
      Only a ranking that leads with the score can put the older one first.

    * **Cross-org exclusion.** Asserting only on the two lists leaves `:total`
      free to keep counting the foreign meeting, which leaks how many
      meetings another org held. `:total` is asserted explicitly.

  Likewise, "a cancelled meeting shows up in `:others`" passes vacuously on a
  query that matched nothing at all, so that test asserts a matching meeting
  in the same run.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Archive
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.Transcript
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task
  alias Platform.Tenancy.OrgMembership

  # A term with no English stem neighbours and no presence in any other
  # fixture, so a match is unambiguously the one this test planted.
  @term "arrowhead"

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp create_user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "archive-#{n}@example.com",
      name: "Archive Reader #{n}",
      oidc_sub: "oidc-archive-#{n}"
    })
    |> Repo.insert!()
  end

  # A plain member — deliberately not "admin", which `fabrikam_admin?/1` would
  # read as "sees every org" and quietly defeat the cross-org test.
  defp member!(user, org_id) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: "member"})
    |> Repo.insert!()

    user
  end

  defp viewer_in_fabrikam! do
    create_user!() |> member!(fabrikam_org_id())
  end

  defp create_meeting!(name, opts \\ []) do
    org_id = Keyword.get(opts, :org_id, fabrikam_org_id())
    n = System.unique_integer([:positive])

    {:ok, project} = Tasks.create_project(%{name: "Archive Project #{n}", org_id: org_id})
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})

    meeting
  end

  # `end_meeting/1` stamps `DateTime.utc_now()`, and these tests need the
  # ordering axis under their own control, so the transitions are driven
  # through the same `status_changeset/3` with explicit timestamps.
  defp end_meeting!(%Meeting{} = meeting, ended_at) do
    {:ok, live} =
      meeting |> Meeting.status_changeset("live", %{started_at: ended_at}) |> Repo.update()

    {:ok, ended} =
      live |> Meeting.status_changeset("ended", %{ended_at: ended_at}) |> Repo.update()

    ended
  end

  defp cancel_meeting!(%Meeting{} = meeting, cancelled_at) do
    {:ok, cancelled} =
      meeting
      |> Meeting.status_changeset("cancelled", %{cancelled_at: cancelled_at})
      |> Repo.update()

    cancelled
  end

  defp go_live!(%Meeting{} = meeting) do
    {:ok, live} =
      meeting
      |> Meeting.status_changeset("live", %{started_at: DateTime.utc_now()})
      |> Repo.update()

    live
  end

  defp participant!(%Meeting{} = meeting) do
    {:ok, participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now(),
        display_name: "Author"
      })

    participant
  end

  defp canvas!(%Meeting{} = meeting, title) do
    {:ok, canvas} =
      Chat.create_canvas(%{
        space_id: meeting.chat_space_id,
        created_by: participant!(meeting).id,
        title: title
      })

    canvas
  end

  defp transcript!(%Meeting{} = meeting, attrs) do
    %Transcript{}
    |> Transcript.changeset(
      Map.merge(
        %{room_id: "room-#{Ecto.UUID.generate()}", space_id: meeting.chat_space_id},
        attrs
      )
    )
    |> Repo.insert!()
  end

  # An action item as the triage pipeline leaves it: a `tasks` row whose
  # `metadata.source_canvas_id` points at a canvas in the meeting's space.
  # Inserted directly rather than through `Tasks.create_task/2`, which fires
  # an async memory ingest that would check a connection out of the sandbox.
  defp action_item!(%Meeting{} = meeting, title) do
    canvas = canvas!(meeting, "Action items")

    %Task{}
    |> Task.changeset(%{
      project_id: meeting.project_id,
      title: title,
      metadata: %{"source_canvas_id" => canvas.id}
    })
    |> Repo.insert!()
  end

  defp ago(days), do: DateTime.add(DateTime.utc_now(), -days, :day)

  defp ids(entries), do: Enum.map(entries, & &1.id)

  # ── 1. Relevance over recency ──────────────────────────────────────────────

  describe "search/2 ranking" do
    test "a canvas title outranks a more recent meeting whose only hit is a transcript segment" do
      viewer = viewer_in_fabrikam!()

      older = create_meeting!("Platform sync alpha")
      canvas!(older, "#{@term} rollout plan")
      older = end_meeting!(older, ago(30))

      newer = create_meeting!("Platform sync beta")
      transcript!(newer, %{segments: [%{"text" => "we should revisit #{@term} next week"}]})
      newer = end_meeting!(newer, ago(1))

      result = Archive.search(viewer, query: @term)

      # Both must be in the matched partition, or "ranked above" is a
      # statement about which partition they landed in rather than about the
      # ordering — and pure recency would satisfy it.
      assert MapSet.new(ids(result.matches)) == MapSet.new([older.id, newer.id]),
             "both meetings must match, otherwise the ordering assertion below " <>
               "is about partitioning, not ranking"

      assert result.matched == 2
      assert result.others == []

      assert hd(result.matches).id == older.id,
             "the older meeting matched at weight B (canvas title) and the newer " <>
               "at weight D (transcript segment) — leading with ended_at instead " <>
               "of the score puts the newer one first"

      # Scores must be distinct, or the tie-break is doing the work and the
      # assertion above says nothing about the score.
      [first, second] = result.matches
      assert first.score > second.score
    end
  end

  # ── 2. Cross-org ───────────────────────────────────────────────────────────

  describe "search/2 viewer scoping" do
    test "a meeting in an org the viewer has no membership in is in neither partition, and is not counted" do
      viewer = viewer_in_fabrikam!()

      mine = create_meeting!("Fabrikam planning")
      canvas!(mine, "#{@term} rollout plan")
      mine = end_meeting!(mine, ago(3))

      theirs = create_meeting!("Soylent planning", org_id: tenant_org_id("soylent"))
      canvas!(theirs, "#{@term} rollout plan")
      theirs = end_meeting!(theirs, ago(2))

      result = Archive.search(viewer, query: @term)

      assert ids(result.matches) == [mine.id]
      assert result.others == []
      refute theirs.id in ids(result.matches)
      refute theirs.id in ids(result.others)

      # The lists alone are not enough: a count computed off an unscoped
      # query still tells the viewer how many meetings the other org held.
      assert result.total == 1
      assert result.matched == 1
    end

    test "a fabrikam root admin sees every org's meetings" do
      admin = create_user!()

      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: admin.id, org_id: fabrikam_org_id(), role: "admin"})
      |> Repo.insert!()

      mine = create_meeting!("Fabrikam planning")
      mine = end_meeting!(mine, ago(3))

      theirs = create_meeting!("Soylent planning", org_id: tenant_org_id("soylent"))
      theirs = end_meeting!(theirs, ago(2))

      result = Archive.search(admin, [])

      assert MapSet.new(ids(result.others)) == MapSet.new([mine.id, theirs.id])
      assert result.total == 2
    end
  end

  # ── 3. Blank query ─────────────────────────────────────────────────────────

  describe "search/2 with a blank query" do
    test "returns every in-scope meeting in others, with matched: 0 and no calendar meetings" do
      viewer = viewer_in_fabrikam!()

      ended = create_meeting!("Retention review") |> end_meeting!(ago(5))
      cancelled = create_meeting!("Budget sync") |> cancel_meeting!(ago(2))
      scheduled = create_meeting!("Upcoming standup")
      live = create_meeting!("Standup in progress") |> go_live!()

      result = Archive.search(viewer, query: "  ")

      assert result.matches == []
      assert result.matched == 0
      assert result.total == 2
      assert MapSet.new(ids(result.others)) == MapSet.new([ended.id, cancelled.id])

      refute scheduled.id in ids(result.others)
      refute live.id in ids(result.others)

      # Ordered by when they left the calendar, newest first: the cancelled
      # meeting has no `ended_at` at all, so its `cancelled_at` is what places
      # it.
      assert ids(result.others) == [cancelled.id, ended.id]

      assert result.type_counts == %{canvases: 0, summaries: 0, action_items: 0, transcripts: 0}
    end

    test "an un-queried archive is distinguishable from a query that matched nothing" do
      viewer = viewer_in_fabrikam!()

      ended = create_meeting!("Retention review") |> end_meeting!(ago(5))

      blank = Archive.search(viewer, query: nil)
      missed = Archive.search(viewer, query: "quokka")

      assert ids(blank.others) == [ended.id]
      assert ids(missed.others) == [ended.id]
      assert blank.matched == 0 and missed.matched == 0

      assert blank.query == ""
      assert missed.query == "quokka"
      refute blank == missed
    end
  end

  # ── 4. Cancelled meetings with no artifacts ────────────────────────────────

  describe "search/2 partitioning" do
    test "a cancelled meeting with no artifacts sits in others while another meeting matches" do
      viewer = viewer_in_fabrikam!()

      cancelled = create_meeting!("Budget sync") |> cancel_meeting!(ago(4))

      matching = create_meeting!("Platform sync")
      canvas!(matching, "#{@term} rollout plan")
      matching = end_meeting!(matching, ago(6))

      result = Archive.search(viewer, query: @term)

      # Asserted together: "the cancelled meeting is present" is satisfied by
      # a query that returned every meeting, so the matched side has to be
      # pinned in the same run.
      assert ids(result.matches) == [matching.id]
      assert result.matched == 1
      assert ids(result.others) == [cancelled.id]
      assert result.total == 2
    end
  end

  # ── Type filtering and counts ──────────────────────────────────────────────

  describe "search/2 type counts and filters" do
    test "counts matching meetings per artifact type and narrows on :types" do
      viewer = viewer_in_fabrikam!()

      by_canvas = create_meeting!("Alpha")
      canvas!(by_canvas, "#{@term} rollout plan")
      by_canvas = end_meeting!(by_canvas, ago(1))

      by_summary = create_meeting!("Beta")
      transcript!(by_summary, %{summary: "The team agreed to ship #{@term} in June."})
      by_summary = end_meeting!(by_summary, ago(2))

      by_segment = create_meeting!("Gamma")
      transcript!(by_segment, %{segments: [%{"text" => "let us talk about #{@term}"}]})
      by_segment = end_meeting!(by_segment, ago(3))

      by_action = create_meeting!("Delta")
      action_item!(by_action, "Ship the #{@term} migration")
      by_action = end_meeting!(by_action, ago(4))

      result = Archive.search(viewer, query: @term)

      assert result.matched == 4
      assert result.total == 4

      assert result.type_counts == %{
               canvases: 1,
               summaries: 1,
               transcripts: 1,
               action_items: 1
             }

      canvases_only = Archive.search(viewer, query: @term, types: [:canvases])

      assert ids(canvases_only.matches) == [by_canvas.id]

      assert MapSet.new(ids(canvases_only.others)) ==
               MapSet.new([by_summary.id, by_segment.id, by_action.id])

      # The chip counts stay whole-archive even under a narrowed filter, so
      # an unselected chip can still advertise what it would reveal.
      assert canvases_only.type_counts == result.type_counts

      action_items_only = Archive.search(viewer, query: @term, types: [:action_items])

      assert ids(action_items_only.matches) == [by_action.id],
             "action-item titles are reached by the two-hop canvas join and " <>
               "scored at query time — an empty result here means the join, not " <>
               "the ranking, is wrong"
    end

    test "the meeting name is always searched, whatever :types says" do
      viewer = viewer_in_fabrikam!()

      by_name = create_meeting!("#{@term} kickoff") |> end_meeting!(ago(1))

      result = Archive.search(viewer, query: @term, types: [:canvases])

      assert ids(result.matches) == [by_name.id]
    end
  end

  # ── Paging ─────────────────────────────────────────────────────────────────

  describe "search/2 paging" do
    test "limit and offset page across the seam between the two partitions" do
      viewer = viewer_in_fabrikam!()

      matching = create_meeting!("Platform sync")
      canvas!(matching, "#{@term} rollout plan")
      matching = end_meeting!(matching, ago(9))

      recent = create_meeting!("Budget sync") |> end_meeting!(ago(1))
      older = create_meeting!("Design review") |> end_meeting!(ago(20))

      first = Archive.search(viewer, query: @term, limit: 1, offset: 0)
      assert ids(first.matches) == [matching.id]
      assert first.others == []

      second = Archive.search(viewer, query: @term, limit: 1, offset: 1)
      assert second.matches == []
      assert ids(second.others) == [recent.id]

      third = Archive.search(viewer, query: @term, limit: 1, offset: 2)
      assert third.matches == []
      assert ids(third.others) == [older.id]

      # `:matched` and `:total` describe the whole result set, not the page.
      assert third.matched == 1
      assert third.total == 3
    end
  end

  # ── Scope filters ──────────────────────────────────────────────────────────

  describe "search/2 scope filters" do
    test "narrows to a project" do
      viewer = viewer_in_fabrikam!()

      keep = create_meeting!("Kept") |> end_meeting!(ago(1))
      drop = create_meeting!("Dropped") |> end_meeting!(ago(2))

      result = Archive.search(viewer, project_id: keep.project_id)

      assert ids(result.others) == [keep.id]
      refute drop.id in ids(result.others)
      assert result.total == 1
    end

    test "narrows to a person's meetings" do
      viewer = viewer_in_fabrikam!()
      person_id = Ecto.UUID.generate()

      attended = create_meeting!("Attended")

      {:ok, _} =
        Chat.add_participant(attended.chat_space_id, %{
          participant_type: "user",
          participant_id: person_id,
          joined_at: DateTime.utc_now(),
          display_name: "Someone"
        })

      attended = end_meeting!(attended, ago(1))
      skipped = create_meeting!("Skipped") |> end_meeting!(ago(2))

      result = Archive.search(viewer, person_id: person_id)

      assert ids(result.others) == [attended.id]
      refute skipped.id in ids(result.others)
    end

    test "a malformed filter id narrows to nothing instead of raising or widening" do
      viewer = viewer_in_fabrikam!()

      create_meeting!("Fabrikam planning") |> end_meeting!(ago(1))

      # `where: m.project_id == ^"not-a-uuid"` raises Ecto.Query.CastError,
      # and these ids come off a params map. Both the raise and the
      # fail-open alternative — dropping the filter and listing every
      # project — are wrong answers.
      for opts <- [[project_id: "not-a-uuid"], [person_id: "system"]] do
        result = Archive.search(viewer, opts)

        assert result.matches == []
        assert result.others == []
        assert result.total == 0
      end
    end
  end

  # ── Unauthenticated ────────────────────────────────────────────────────────

  describe "search/2 with no viewer" do
    test "returns nothing rather than everything" do
      create_meeting!("Fabrikam planning") |> end_meeting!(ago(1))

      result = Archive.search(nil, [])

      assert result.matches == []
      assert result.others == []
      assert result.total == 0
    end
  end

  # ── External viewers: invitation, not org membership ───────────────────────
  #
  # Every negative below is paired with a positive control in the SAME test.
  # An archive that returned nothing at all for every external viewer would
  # satisfy all three refutations, and that is a bug, not a pass.

  describe "search/2 for an external viewer" do
    test "an invited meeting they never attended appears; an uninvited one in the SAME org does not" do
      org_id = tenant_org_id("soylent")
      external = create_user!() |> external_member!(org_id)
      insider = create_user!() |> member!(org_id)

      invited =
        create_meeting!("Soylent invited review", org_id: org_id) |> end_meeting!(ago(4))

      uninvited =
        create_meeting!("Soylent internal retro", org_id: org_id) |> end_meeting!(ago(3))

      invite!(invited, %{user_id: external.id})

      refute Chat.participant?(invited.chat_space_id, external.id),
             "fixture precondition: invited-but-absent, no participant row"

      insider_ids = archive_ids(insider)

      assert invited.id in insider_ids and uninvited.id in insider_ids,
             "positive control: both rows exist and an internal viewer sees them"

      ids = archive_ids(external)
      assert invited.id in ids, "positive control: the invited row appears"
      refute uninvited.id in ids, "same-org membership must not widen an external archive"
    end

    test "attending without an invite does not surface the meeting" do
      org_id = tenant_org_id("soylent")
      external = create_user!() |> external_member!(org_id)

      attended = create_meeting!("Soylent attended", org_id: org_id) |> end_meeting!(ago(4))
      invited = create_meeting!("Soylent invited", org_id: org_id) |> end_meeting!(ago(3))

      seat!(attended, external)
      invite!(invited, %{user_id: external.id})

      assert Chat.participant?(attended.chat_space_id, external.id),
             "fixture precondition: the participation really is there"

      ids = archive_ids(external)
      assert invited.id in ids, "positive control: the invited meeting appears"
      refute attended.id in ids, "participation is not invitation"
    end

    test "a revoked invite disappears while a live invite in the same run remains" do
      org_id = tenant_org_id("soylent")
      external = create_user!() |> external_member!(org_id)

      revoked_meeting =
        create_meeting!("Soylent revoked", org_id: org_id) |> end_meeting!(ago(4))

      live_meeting =
        create_meeting!("Soylent live invite", org_id: org_id) |> end_meeting!(ago(3))

      revoked = invite!(revoked_meeting, %{user_id: external.id})
      invite!(live_meeting, %{user_id: external.id})
      # Revocation leaves the participant row behind — the reason the rule
      # cannot key on participation.
      seat!(revoked_meeting, external)

      assert revoked_meeting.id in archive_ids(external),
             "positive control: it appears BEFORE revocation"

      {:ok, _} = Meetings.revoke_invite(revoked)

      ids = archive_ids(external)
      assert live_meeting.id in ids, "positive control: the live invite survives"
      refute revoked_meeting.id in ids
    end

    test "counts and filters compose on top of the narrowed set" do
      org_id = tenant_org_id("soylent")
      external = create_user!() |> external_member!(org_id)

      invited = create_meeting!("Soylent counted", org_id: org_id)
      canvas!(invited, "#{@term} rollout plan")
      invited = end_meeting!(invited, ago(4))

      uninvited = create_meeting!("Soylent uncounted", org_id: org_id)
      canvas!(uninvited, "#{@term} rollout plan")
      uninvited = end_meeting!(uninvited, ago(3))

      invite!(invited, %{user_id: external.id})

      result = Archive.search(external, query: @term)

      assert ids(result.matches) == [invited.id], "positive control: the invited row matches"
      assert result.total == 1
      assert result.matched == 1
      refute uninvited.id in ids(result.others)

      # `:project_id` still narrows, and a malformed one still fails closed.
      kept = Archive.search(external, project_id: invited.project_id)
      assert ids(kept.others) ++ ids(kept.matches) == [invited.id]
      assert Archive.search(external, project_id: "not-a-uuid").total == 0
    end

    test "artifacts_for/2 is gated by the same rule, independently of search/2" do
      org_id = tenant_org_id("soylent")
      external = create_user!() |> external_member!(org_id)
      insider = create_user!() |> member!(org_id)

      invited = create_meeting!("Soylent artifacts in", org_id: org_id)
      canvas!(invited, "#{@term} rollout plan")
      invited = end_meeting!(invited, ago(4))

      uninvited = create_meeting!("Soylent artifacts out", org_id: org_id)
      canvas!(uninvited, "#{@term} rollout plan")
      uninvited = end_meeting!(uninvited, ago(3))

      invite!(invited, %{user_id: external.id})

      insider_artifacts = Archive.artifacts_for(insider, [invited, uninvited])

      assert Map.has_key?(insider_artifacts, uninvited.id),
             "positive control: the row does have artifacts for someone entitled to them"

      # Handed BOTH ids directly — the gate must hold without relying on
      # `search/2` having filtered the list first.
      artifacts = Archive.artifacts_for(external, [invited, uninvited])
      assert Map.has_key?(artifacts, invited.id), "positive control: the invited row resolves"
      refute Map.has_key?(artifacts, uninvited.id)
    end
  end

  # ── External fixtures ──────────────────────────────────────────────────────

  defp external_member!(user, org_id) do
    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: org_id,
      role: "member",
      external: true
    })
    |> Repo.insert!()

    user
  end

  defp invite!(%Meeting{} = meeting, attrs) do
    %Invite{}
    |> Invite.changeset(
      Map.merge(%{meeting_id: meeting.id, display_name: "Archive Invitee"}, attrs)
    )
    |> Repo.insert!()
  end

  defp seat!(%Meeting{} = meeting, user) do
    {:ok, participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp archive_ids(viewer) do
    result = Archive.search(viewer, [])
    ids(result.matches) ++ ids(result.others)
  end
end
