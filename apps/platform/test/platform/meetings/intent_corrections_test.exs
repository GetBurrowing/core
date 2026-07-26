defmodule Platform.Meetings.IntentCorrectionsTest do
  @moduledoc """
  Tests for `Platform.Meetings.IntentCorrections` — the context that
  writes the durable few-shot corpus and reads it back as classifier
  exemplars (task 019f70b8 stage 6).

  ## Nothing here hands the context an org

  Every case that cares about org scoping builds a REAL
  `org -> project -> meeting` chain and lets `create_correction/1`
  derive `org_id` the way production will. Passing the org in would go
  green against a context that ignored the meeting entirely — which is
  precisely the hole stage 3 found in `Meetings.append_segment/2`, where
  `meeting_id: nil` was hardcoded behind a comment claiming something
  downstream enriched it and every test passed the id in by hand. The
  two-org cases below are the ones that would catch it: they only
  separate if the derivation actually walks
  `meetings.project_id -> projects.org_id`.

  The single exception is `recent_exemplars/2`'s own ordering/limit
  cases, which are about the query and take a bare org id on purpose.
  """

  use Platform.DataCase, async: true

  import Platform.TenancyFixtures

  alias Platform.Meetings.IntentCorrection
  alias Platform.Meetings.IntentCorrections
  alias Platform.Repo

  # ── Real association chain ────────────────────────────────────────────────

  defp create_meeting!(org_id) do
    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Intent Corrections #{System.unique_integer([:positive])}",
        org_id: org_id
      })

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Meeting Space #{System.unique_integer([:positive])}",
        slug: "intent-corrections-#{System.unique_integer([:positive])}",
        kind: "meeting"
      })

    %Platform.Meetings.Meeting{}
    |> Platform.Meetings.Meeting.changeset(%{
      project_id: project.id,
      chat_space_id: space.id,
      slug: "corrections-#{System.unique_integer([:positive])}",
      name: "Corrections Meeting",
      livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
    })
    |> Repo.insert!()
  end

  defp correction_attrs(meeting_id, overrides \\ %{}) do
    Map.merge(
      %{
        meeting_id: meeting_id,
        transcript_chunk_excerpt: "let's make that button teal",
        classified_intent: "visual_adjust",
        correction: :removed_no_action,
        reason: :not_actionable
      },
      overrides
    )
  end

  # ── create_correction/1 ───────────────────────────────────────────────────

  describe "create_correction/1 — org derivation" do
    test "derives org_id from the meeting's project" do
      org_id = fabrikam_org_id()
      meeting = create_meeting!(org_id)

      {:ok, correction} = IntentCorrections.create_correction(correction_attrs(meeting.id))

      assert correction.org_id == org_id
    end

    test "two meetings in different orgs derive different org_ids" do
      fabrikam = fabrikam_org_id()
      sxi = tenant_org_id("sxi")

      fabrikam_meeting = create_meeting!(fabrikam)
      sxi_meeting = create_meeting!(sxi)

      {:ok, fabrikam_correction} =
        IntentCorrections.create_correction(correction_attrs(fabrikam_meeting.id))

      {:ok, sxi_correction} =
        IntentCorrections.create_correction(correction_attrs(sxi_meeting.id))

      assert fabrikam_correction.org_id == fabrikam
      assert sxi_correction.org_id == sxi
      refute fabrikam_correction.org_id == sxi_correction.org_id
    end

    test "an explicit org_id wins over derivation" do
      # The stage-7 UI already holds an org and should not pay for a
      # lookup it can answer itself.
      meeting = create_meeting!(fabrikam_org_id())
      explicit = tenant_org_id("paragon")

      {:ok, correction} =
        IntentCorrections.create_correction(correction_attrs(meeting.id, %{org_id: explicit}))

      assert correction.org_id == explicit
    end

    test "an explicit nil org_id still derives — nil is 'I don't know', not 'leave it empty'" do
      org_id = fabrikam_org_id()
      meeting = create_meeting!(org_id)

      {:ok, correction} =
        IntentCorrections.create_correction(correction_attrs(meeting.id, %{org_id: nil}))

      assert correction.org_id == org_id
    end

    test "a meeting id with no meetings row still writes, with a nil org_id" do
      orphan_meeting_id = Platform.Types.UUIDv7.generate()

      {:ok, correction} = IntentCorrections.create_correction(correction_attrs(orphan_meeting_id))

      assert is_nil(correction.org_id)
      assert correction.meeting_id == orphan_meeting_id
    end

    test "an invalid row comes back as {:error, changeset}, not a raise" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               IntentCorrections.create_correction(%{meeting_id: nil})

      refute changeset.valid?
    end

    test "string-keyed attrs (a LiveView form) derive too, without mixing key types" do
      org_id = fabrikam_org_id()
      meeting = create_meeting!(org_id)

      {:ok, correction} =
        IntentCorrections.create_correction(%{
          "meeting_id" => meeting.id,
          "classified_intent" => "visual_adjust",
          "correction" => "removed_no_action",
          "reason" => "not_actionable"
        })

      assert correction.org_id == org_id
    end
  end

  # ── org_id_for_meeting/1 ──────────────────────────────────────────────────

  describe "org_id_for_meeting/1" do
    test "walks meetings.project_id -> projects.org_id" do
      org_id = tenant_org_id("soylent")
      meeting = create_meeting!(org_id)

      assert IntentCorrections.org_id_for_meeting(meeting.id) == org_id
    end

    test "nil for an unknown meeting" do
      assert is_nil(IntentCorrections.org_id_for_meeting(Platform.Types.UUIDv7.generate()))
    end

    test "nil for a nil meeting id" do
      assert is_nil(IntentCorrections.org_id_for_meeting(nil))
    end

    test "nil rather than a raise for a malformed meeting id" do
      # Transcript payloads are not schema-validated on the way in.
      assert is_nil(IntentCorrections.org_id_for_meeting("not-a-uuid"))
    end
  end

  # ── recent_exemplars/2 ────────────────────────────────────────────────────

  describe "recent_exemplars/2" do
    defp seed_exemplars!(org_id, intents) do
      Enum.map(intents, fn intent ->
        {:ok, correction} =
          IntentCorrections.create_correction(%{
            meeting_id: Platform.Types.UUIDv7.generate(),
            org_id: org_id,
            classified_intent: intent,
            transcript_chunk_excerpt: "utterance for #{intent}",
            correction: :removed_no_action,
            reason: :wrong_intent
          })

        correction
      end)
    end

    test "returns newest first" do
      org_id = fabrikam_org_id()
      [_first, _second, third] = seed_exemplars!(org_id, ~w(one two three))

      assert [newest | _] = IntentCorrections.recent_exemplars(org_id)
      assert newest.id == third.id
    end

    test "orders by inserted_at desc across the whole set" do
      org_id = tenant_org_id("wayne_tech")
      seed_exemplars!(org_id, ~w(a b c d))

      intents = Enum.map(IntentCorrections.recent_exemplars(org_id), & &1.classified_intent)

      assert intents == ~w(d c b a)
    end

    test "honours the limit" do
      org_id = tenant_org_id("paragon")
      seed_exemplars!(org_id, ~w(a b c d e))

      assert length(IntentCorrections.recent_exemplars(org_id, 2)) == 2
      assert length(IntentCorrections.recent_exemplars(org_id, 5)) == 5
    end

    test "the limit keeps the NEWEST rows, not an arbitrary two" do
      org_id = tenant_org_id("sxi")
      seed_exemplars!(org_id, ~w(oldest middle newest))

      intents =
        org_id
        |> IntentCorrections.recent_exemplars(2)
        |> Enum.map(& &1.classified_intent)

      assert intents == ~w(newest middle)
    end

    test "defaults to the documented window" do
      assert IntentCorrections.default_exemplar_limit() == 10

      org_id = tenant_org_id("soylent")
      seed_exemplars!(org_id, Enum.map(1..15, &"intent_#{&1}"))

      assert length(IntentCorrections.recent_exemplars(org_id)) == 10
    end

    test "never returns another org's corrections" do
      fabrikam = fabrikam_org_id()
      sxi = tenant_org_id("sxi")

      seed_exemplars!(fabrikam, ~w(fabrikam_only))
      seed_exemplars!(sxi, ~w(sxi_only))

      fabrikam_intents = Enum.map(IntentCorrections.recent_exemplars(fabrikam), & &1.classified_intent)

      assert "fabrikam_only" in fabrikam_intents
      refute "sxi_only" in fabrikam_intents
    end

    test "a nil org returns [] rather than every org's corrections" do
      # The dangerous failure mode: an unresolvable org silently widening
      # the query to the whole corpus and leaking another tenant's
      # vocabulary into a classification.
      seed_exemplars!(fabrikam_org_id(), ~w(should_not_leak))

      assert IntentCorrections.recent_exemplars(nil) == []
    end
  end

  # ── exemplars_for_meeting/2 ───────────────────────────────────────────────

  describe "exemplars_for_meeting/2" do
    test "resolves the meeting's org and returns only that org's exemplars" do
      fabrikam = fabrikam_org_id()
      sxi = tenant_org_id("sxi")

      fabrikam_meeting = create_meeting!(fabrikam)

      {:ok, _} =
        IntentCorrections.create_correction(
          correction_attrs(fabrikam_meeting.id, %{classified_intent: "fabrikam_intent"})
        )

      sxi_meeting = create_meeting!(sxi)

      {:ok, _} =
        IntentCorrections.create_correction(
          correction_attrs(sxi_meeting.id, %{classified_intent: "sxi_intent"})
        )

      intents =
        fabrikam_meeting.id
        |> IntentCorrections.exemplars_for_meeting(10)
        |> Enum.map(& &1.classified_intent)

      assert "fabrikam_intent" in intents
      refute "sxi_intent" in intents
    end

    test "sees corrections written from OTHER meetings in the same org" do
      # The corpus is org-scoped, not meeting-scoped: a correction made
      # in yesterday's meeting must tune today's.
      org_id = tenant_org_id("wayne_tech")
      yesterday = create_meeting!(org_id)
      today = create_meeting!(org_id)

      {:ok, _} =
        IntentCorrections.create_correction(
          correction_attrs(yesterday.id, %{classified_intent: "learned_yesterday"})
        )

      intents =
        today.id
        |> IntentCorrections.exemplars_for_meeting(10)
        |> Enum.map(& &1.classified_intent)

      assert "learned_yesterday" in intents
    end

    test "[] for a nil meeting id" do
      assert IntentCorrections.exemplars_for_meeting(nil, 10) == []
    end

    test "[] for a meeting whose org cannot be resolved" do
      assert IntentCorrections.exemplars_for_meeting(Platform.Types.UUIDv7.generate(), 10) == []
    end
  end

  # ── list_for_meeting/2 ────────────────────────────────────────────────────

  describe "list_for_meeting/2" do
    test "returns this meeting's corrections, newest first" do
      meeting = create_meeting!(fabrikam_org_id())

      for intent <- ~w(first second third) do
        {:ok, _} =
          IntentCorrections.create_correction(
            correction_attrs(meeting.id, %{classified_intent: intent})
          )
      end

      intents =
        meeting.id
        |> IntentCorrections.list_for_meeting()
        |> Enum.map(& &1.classified_intent)

      assert intents == ~w(third second first)
    end

    test "excludes other meetings in the same org" do
      org_id = fabrikam_org_id()
      mine = create_meeting!(org_id)
      theirs = create_meeting!(org_id)

      {:ok, _} =
        IntentCorrections.create_correction(
          correction_attrs(mine.id, %{classified_intent: "mine"})
        )

      {:ok, _} =
        IntentCorrections.create_correction(
          correction_attrs(theirs.id, %{classified_intent: "theirs"})
        )

      intents =
        mine.id
        |> IntentCorrections.list_for_meeting()
        |> Enum.map(& &1.classified_intent)

      assert intents == ["mine"]
    end

    test "honours a limit" do
      meeting = create_meeting!(fabrikam_org_id())

      for intent <- ~w(a b c) do
        {:ok, _} =
          IntentCorrections.create_correction(
            correction_attrs(meeting.id, %{classified_intent: intent})
          )
      end

      assert length(IntentCorrections.list_for_meeting(meeting.id, 2)) == 2
    end
  end

  # ── AC17 ──────────────────────────────────────────────────────────────────

  describe "AC17 — the corpus is a record of being wrong" do
    test "the context itself writes nothing on construction" do
      before_count = Repo.aggregate(IntentCorrection, :count)

      # Reading the corpus, resolving orgs, and listing exemplars are all
      # pure reads. A context whose read path wrote a row would poison the
      # corpus with examples of correct behaviour labelled as errors.
      meeting = create_meeting!(fabrikam_org_id())
      _ = IntentCorrections.org_id_for_meeting(meeting.id)
      _ = IntentCorrections.exemplars_for_meeting(meeting.id, 10)
      _ = IntentCorrections.recent_exemplars(fabrikam_org_id())
      _ = IntentCorrections.list_for_meeting(meeting.id)

      assert Repo.aggregate(IntentCorrection, :count) == before_count
    end
  end
end
