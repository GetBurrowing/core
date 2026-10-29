defmodule Platform.Meetings.Synthesis.PassTest do
  use Platform.DataCase, async: false
  import Platform.TenancyFixtures
  alias Platform.{Repo, Meetings, Tasks}

  alias Platform.Meetings.{
    Completion,
    CompletionRun,
    MeetingBriefings,
    Participant,
    Room,
    SynthesisFindings,
    Transcript
  }

  alias Platform.Meetings.Synthesis
  alias Platform.Meetings.Synthesis.Parser

  defmodule Provider do
    def chat(_credentials, [%{content: content}], opts) do
      send(Application.fetch_env!(:platform, :synthesis_test_pid), {:provider, content, opts})
      if Application.get_env(:platform, :synthesis_test_mode) == :raise, do: raise("stub failure")

      summaries =
        Jason.decode!(content)
        |> Enum.filter(&String.starts_with?(&1["ref"], "meeting_briefing:"))

      refs = Enum.map(summaries, & &1["ref"])

      refs =
        case Application.get_env(:platform, :synthesis_test_mode) do
          :unknown -> ["meeting_briefing:unknown" | refs]
          :one_side -> Enum.take(refs, 1)
          _ -> refs
        end

      cites = Enum.map_join(refs, "", &"<cite ref=\"#{&1}\"/>")

      {:ok,
       %{
         content:
           "<meeting-finding kind=\"conflicts_with\" confidence=\"high\">Friday conflicts with Monday.#{cites}</meeting-finding>"
       }}
    end
  end

  setup do
    keys = [
      :meetings_summary,
      :meeting_synthesis_provider,
      :synthesis_test_pid,
      :synthesis_test_mode
    ]

    old = Map.new(keys, &{&1, Application.fetch_env(:platform, &1)})

    on_exit(fn ->
      Enum.each(old, fn {k, v} ->
        case v do
          {:ok, value} -> Application.put_env(:platform, k, value)
          :error -> Application.delete_env(:platform, k)
        end
      end)
    end)

    Application.put_env(:platform, :meetings_summary, %{provider: :openai})
    Application.put_env(:platform, :meeting_synthesis_provider, Provider)
    Application.put_env(:platform, :synthesis_test_pid, self())
    Application.delete_env(:platform, :synthesis_test_mode)
    Platform.Orchestration.PromptTemplates.seed_defaults()
    n = System.unique_integer([:positive])

    u =
      Repo.insert!(%Platform.Accounts.User{
        email: "synthpass-#{n}@example.com",
        name: "Reader",
        oidc_sub: "synthpass-#{n}"
      })

    Repo.insert!(
      Platform.Tenancy.OrgMembership.changeset(%Platform.Tenancy.OrgMembership{}, %{
        user_id: u.id,
        org_id: acme_org_id(),
        role: "member"
      })
    )

    {:ok, project} = Tasks.create_project(%{name: "Synthesis pass #{n}", org_id: acme_org_id()})
    a = meeting!(project, u, "Release Friday")
    b = meeting!(project, u, "Release Monday")
    %{a: a, b: b, user: u}
  end

  defp meeting!(project, u, title) do
    now = DateTime.utc_now()
    {:ok, m} = Meetings.create_meeting(%{project_id: project.id, name: title})

    m =
      Repo.update!(
        Ecto.Changeset.change(m,
          status: "ended",
          started_at: DateTime.add(now, -600),
          ended_at: DateTime.add(now, -10)
        )
      )

    room =
      Repo.insert!(
        Room.changeset(%Room{}, %{space_id: m.chat_space_id, livekit_room_name: "synth-#{m.id}"})
      )

    Repo.insert!(
      Participant.changeset(%Participant{}, %{
        room_id: room.id,
        user_id: u.id,
        display_name: u.name,
        joined_at: DateTime.add(now, -500)
      })
    )

    {:ok, _} =
      Platform.Chat.add_participant(m.chat_space_id, %{
        participant_type: "user",
        participant_id: u.id,
        display_name: u.name,
        joined_at: now
      })

    t =
      Repo.insert!(%Transcript{
        space_id: m.chat_space_id,
        meeting_id: m.id,
        room_id: m.livekit_room_name,
        started_at: DateTime.add(now, -500),
        status: "complete",
        summary: title,
        segments: [%{"id" => Ecto.UUID.generate(), "text" => title, "start_time" => 1}]
      })

    Repo.update!(Ecto.Changeset.change(t, summary_input_hash: Transcript.summary_fingerprint(t)))
    {:ok, snap, _} = Completion.snapshot(m)

    r = %CompletionRun{
      meeting_id: m.id,
      transcript_id: t.id,
      capture_finished_at: now,
      status: "filed",
      snapshot: snap
    }

    hash = Completion.snapshot_hash(r, snap)

    r =
      Repo.insert!(%{
        r
        | snapshot_hash: hash,
          synthesis: %{"snapshot_hash" => hash, "status" => "pending"}
      })

    {:ok, _, _} = MeetingBriefings.build(m)
    {m, r}
  end

  test "conflicting meetings persist one grounded finding and intersect recipients", %{
    a: {a, r},
    user: u
  } do
    assert {:ok, [_]} = Synthesis.run(a.id, r.id, r.snapshot_hash)
    assert [f] = SynthesisFindings.list_for_meeting(a.id)
    assert f.kind == "conflicts_with"
    assert length(f.citations) == 2
    assert f.recipient_user_ids == [u.id]
    assert Repo.get!(CompletionRun, r.id).synthesis["status"] == "complete"
    assert_receive {:provider, content, opts}
    refute Keyword.has_key?(opts, :tools)
    refute String.contains?(content, "reader_ids")
    assert {:error, :stale_or_claimed} = Synthesis.run(a.id, r.id, r.snapshot_hash)
  end

  for mode <- [:unknown, :one_side] do
    test "drops #{mode} output", %{a: {a, r}} do
      Application.put_env(:platform, :synthesis_test_mode, unquote(mode))
      assert {:ok, []} = Synthesis.run(a.id, r.id, r.snapshot_hash)
      assert SynthesisFindings.list_for_meeting(a.id) == []
      assert Repo.get!(CompletionRun, r.id).synthesis["status"] == "complete"
    end
  end

  test "provider none skips and releases delivery", %{a: {a, r}} do
    Application.put_env(:platform, :meetings_summary, %{provider: :none})
    assert "synthesis" in MeetingBriefings.readiness(a).missing
    assert {:ok, :pending} = MeetingBriefings.deliver(a)
    assert {:ok, :skipped} = Synthesis.run(a.id, r.id, r.snapshot_hash)
    refute_receive {:provider, _, _}
    assert MeetingBriefings.readiness(a).ready?
    assert {:ok, %{created: _}} = MeetingBriefings.deliver(a)
    assert SynthesisFindings.list_for_meeting(a.id) == []
  end

  test "raising provider marks complete and delivers", %{a: {a, r}} do
    Application.put_env(:platform, :synthesis_test_mode, :raise)
    refute MeetingBriefings.readiness(a).ready?
    assert {:error, :synthesis_failed} = Synthesis.run(a.id, r.id, r.snapshot_hash)
    assert Repo.get!(CompletionRun, r.id).synthesis["status"] == "complete"
    assert MeetingBriefings.readiness(a).ready?
    assert {:ok, %{created: _}} = MeetingBriefings.deliver(a)
  end

  test "resolution metric counts judged findings once and distinguishes no data", %{a: {a, r}} do
    metric = Platform.Experiments.Metrics.MeetingSynthesisResolutionRate

    {:ok, experiment} =
      Platform.Experiments.create_experiment(%{
        slug: "meeting-metric-#{System.unique_integer([:positive])}",
        name: "Meeting metric",
        status: "draft"
      })

    Repo.insert!(%Platform.Experiments.Assignment{
      experiment_id: experiment.id,
      subject_type: "meeting",
      subject_id: a.id,
      variant_slug: "control",
      assigned_at: DateTime.utc_now()
    })

    assert :insufficient_data = metric.compute(experiment.id, "control")
    assert {:ok, [f]} = Synthesis.run(a.id, r.id, r.snapshot_hash)
    assert :insufficient_data = metric.compute(experiment.id, "control")
    Repo.update!(Ecto.Changeset.change(f, receipt: %{"verb" => "confirmed"}))
    assert {:ok, %{value: 1.0, n: 1, unit: :ratio}} = metric.compute(experiment.id, "control")
    f = Repo.get!(Platform.Meetings.SynthesisFinding, f.id)
    Repo.update!(Ecto.Changeset.change(f, receipt: %{"verb" => "dismissed"}))
    assert {:ok, %{value: 0.0, n: 1}} = metric.compute(experiment.id, "control")
  end

  test "a conflict can have an independent task side, but two citations from one meeting are one side" do
    a = Ecto.UUID.generate()
    task_id = Ecto.UUID.generate()
    summary = %{ref: {:meeting_briefing, a}, text: "Release Friday", meeting_ids: [a]}
    task = %{ref: {:task, task_id}, text: "Release Monday", meeting_ids: []}

    text =
      "<meeting-finding kind=\"conflicts_with\" confidence=\"high\" meetings=\"#{a}\">The release dates conflict.<cite ref=\"meeting_briefing:#{a}\"/><cite ref=\"task:#{task_id}\"/></meeting-finding>"

    assert [_] = Parser.parse(text, [summary, task])
    assert [] = Parser.parse(text, [summary, %{task | meeting_ids: [a]}])
  end

  test "parser requires named sides and minimum confidence" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()
    s = %{ref: {:meeting_briefing, a}, text: "Friday", meeting_ids: [a], reader_ids: []}

    text =
      "<meeting-finding kind=\"depends_on\" confidence=\"medium\" meetings=\"#{a}\">Grounded.<cite ref=\"meeting_briefing:#{a}\"/></meeting-finding>"

    assert [_] = Parser.parse(text, [s])
    assert [] = Parser.parse(text, [s], "high")

    assert [] =
             Parser.parse(String.replace(text, "meetings=\"#{a}\"", "meetings=\"#{a},#{b}\""), [s])
  end
end
