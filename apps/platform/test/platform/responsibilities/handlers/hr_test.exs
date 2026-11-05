defmodule Platform.Responsibilities.Handlers.HrTest do
  @moduledoc """
  Task 01a1aa47 stage 4 — `Platform.Responsibilities.Handlers.Hr`: two rows,
  a persisted started/finished signal on the daily sweep, each subject's own
  words and nobody else's, guarded two-tier writes, ambiguous names written
  nowhere, and no Router fire of its own.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.{Message, Participant}
  alias Platform.Meetings
  alias Platform.Meetings.{Room, Transcript}
  alias Platform.Org.{Wiki, WikiJournalEntry, WikiPage}
  alias Platform.People.{Pages, SweepState, Visibility}
  alias Platform.Repo
  alias Platform.Responsibilities.Handlers.Hr
  alias Platform.Responsibilities.Responsibility

  @agent_id "0193a1b2-0000-7000-8000-00000000aaaa"
  @subject_user_id "0193a1b2-0000-7000-8000-00000000bbbb"
  @now ~U[2026-10-20 10:00:00.000000Z]
  @others_spoken "I think Marisol is slow playing us"

  setup do
    Repo.delete_all(WikiPage)
    Repo.delete_all(WikiJournalEntry)
    :ok
  end

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp responsibility(key) do
    spec = Enum.find(Hr.register(), &(&1.key == key))

    %Responsibility{
      id: Ecto.UUID.generate(),
      key: spec.key,
      feature: spec.feature,
      trigger_kind: spec.trigger_kind,
      trigger_config: spec.trigger_config,
      scope: spec.scope,
      context_provided: spec.context_provided,
      default_prompt_template: spec.default_prompt_template,
      enabled: true
    }
  end

  defp user!(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{email: "hr-#{n}@example.com", name: name, oidc_sub: "hr-#{n}"})
    |> Repo.insert!()
  end

  defp space! do
    {:ok, space} =
      Chat.create_space(%{
        name: "eng",
        slug: "hr-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp participant!(space, user, name) do
    %Participant{}
    |> Participant.changeset(%{
      space_id: space.id,
      participant_type: "user",
      participant_id: user.id,
      display_name: name,
      joined_at: @now
    })
    |> Repo.insert!()
  end

  defp message!(space, participant, user, name, content, at) do
    %Message{}
    |> Message.changeset(%{
      space_id: space.id,
      participant_id: participant.id,
      content_type: "text",
      content: content,
      author_display_name: name,
      author_user_id: user.id,
      author_participant_type: "user"
    })
    |> Ecto.Changeset.put_change(:inserted_at, at)
    |> Repo.insert!()
  end

  defp room!(space) do
    %Room{}
    |> Room.changeset(%{
      space_id: space.id,
      livekit_room_name: "hr-room-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp transcript!(room, space) do
    %Transcript{}
    |> Transcript.changeset(%{
      room_id: room.livekit_room_name,
      space_id: space.id,
      status: "complete",
      started_at: DateTime.add(@now, -30, :minute),
      completed_at: @now,
      summary: "Fixture Founder doubted Marisol's pace",
      segments: [
        %{
          "id" => "s1",
          "speaker_name" => "Fixture Founder",
          "text" => @others_spoken,
          "spoken_at" => "2026-10-20T09:40:00Z"
        },
        %{
          "id" => "s2",
          "speaker_name" => "Marisol Tennebrook",
          "text" => "I will own the pipeline, page me on 904-555-0100",
          "spoken_at" => "2026-10-20T09:41:00Z"
        }
      ]
    })
    |> Repo.insert!()
  end

  defp card!(slug, name, extra \\ "") do
    {:ok, _, _} =
      Pages.write_card(
        nil,
        slug,
        """
        ---
        tier: card
        name: #{name}
        relation: team
        #{extra}
        ---

        ## Role
        """,
        @agent_id
      )
  end

  defp hr_rows(phase) do
    WikiJournalEntry
    |> Repo.all()
    |> Enum.filter(&(&1.metadata["source"] == SweepState.source()))
    |> Enum.filter(&(is_nil(phase) or &1.metadata["phase"] == phase))
    |> Enum.sort_by(& &1.inserted_at, DateTime)
  end

  defp profile(name, extra \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "user_id" => @subject_user_id,
        "relation" => "team",
        "role" => "platform lead",
        "current_projects" => ["deploy pipeline"],
        "interactions" => [
          %{
            "date" => "2026-10-20",
            "kind" => "meeting",
            "title" => "Deploy review",
            "citation" => "meeting:transcript:abc:s2"
          }
        ],
        "perspectives" => [
          %{
            "statement" => "I will own the pipeline",
            "said_by_subject" => true,
            "citation" => "meeting:transcript:abc:s2"
          }
        ],
        "agents" => []
      },
      extra
    )
  end

  defp page(path), do: Wiki.get_page(path, workspace_id: nil)

  # ── register ─────────────────────────────────────────────────────────────

  test "register declares the 04:00 America/Chicago cron row and the meeting:finished row" do
    [daily, meeting] = Hr.register()

    assert daily.key == "hr.daily_sweep"
    assert daily.feature == "hr"
    assert daily.trigger_kind == "cron"
    assert daily.trigger_config == %{"expression" => "0 4 * * *", "timezone" => "America/Chicago"}
    assert daily.scope == "per_org"
    assert daily.default_prompt_template == "hr.profile.v1"
    assert daily.metadata == %{"owner" => "platform.people", "feeds" => "memory.dreaming"}

    assert daily.context_provided == [
             "people_roster",
             "people_appearances",
             "people_staleness",
             "people_own_words",
             "org_identity"
           ]

    assert meeting.key == "hr.meeting_completed"
    assert meeting.feature == "hr"
    assert meeting.trigger_kind == "event_topic"
    assert meeting.trigger_config["topic"] == "meeting:finished"
    assert meeting.trigger_config["topic_pattern"] == "meeting:finished:*"
    assert meeting.trigger_config["event_match"] == "meeting_finished"
    assert meeting.scope == "per_meeting"
    assert meeting.default_prompt_template == "hr.profile.v1"

    # Dreaming's own row is untouched: still 05:00, one hour after HR.
    [dreaming] = Platform.Responsibilities.Handlers.Dreaming.register()

    assert dreaming.trigger_config == %{
             "expression" => "0 5 * * *",
             "timezone" => "America/Chicago"
           }

    for spec <- Hr.register() do
      assert %Ecto.Changeset{valid?: true} = Responsibility.changeset(%Responsibility{}, spec)
    end
  end

  # ── gather_context ───────────────────────────────────────────────────────

  test "gather_context writes a started journal row and refuses when there is nothing to curate" do
    assert SweepState.status(DateTime.utc_now()) == :not_started

    assert {:error, :nothing_to_curate} =
             Hr.gather_context(responsibility("hr.daily_sweep"), %{kind: :cron, fired_at: @now})

    [started] = hr_rows("started")
    assert started.content =~ "HR daily sweep started 2026-10-20T10:00:00"
    assert started.metadata["phase"] == "started"
    assert started.metadata["started_at"] == "2026-10-20T10:00:00.000000Z"

    [finished] = hr_rows("finished")
    assert finished.content =~ "HR daily sweep finished"
    assert finished.content =~ "updated none"
    assert finished.metadata["updated"] == []

    # With something to curate the sweep stays in flight after the gather.
    # Real clock here: the sweep signal is read for the UTC day of the fire.
    Repo.delete_all(WikiJournalEntry)
    fired_at = DateTime.utc_now()
    marisol = user!("Marisol Tennebrook")
    space = space!()
    part = participant!(space, marisol, "Marisol Tennebrook")

    message!(
      space,
      part,
      marisol,
      "Marisol Tennebrook",
      "I prefer small PRs",
      DateTime.add(fired_at, -1, :hour)
    )

    assert {:ok, ctx} =
             Hr.gather_context(responsibility("hr.daily_sweep"), %{
               kind: :cron,
               fired_at: fired_at
             })

    assert [_] = hr_rows("started")
    assert [] = hr_rows("finished")
    assert {:in_flight, _} = SweepState.status(DateTime.utc_now())

    assert ctx.people_appearances =~ "Marisol Tennebrook [human] via chat_author"
    assert ctx.people_staleness =~ "No profile yet:\n- Marisol Tennebrook"
    assert ctx.people_own_words =~ "### Marisol Tennebrook (new)"
    assert ctx.people_own_words =~ "- I prefer small PRs"
    assert ctx.contract == Platform.People.Privacy.subject_reads_it_note()
    assert ctx.page_grammar == Hr.page_grammar()
    assert ctx.experiment_directive == ""
    assert ctx.date == Date.to_iso8601(DateTime.to_date(fired_at))
    assert ctx.workspace_id =~ "org-wide"
    assert Enum.all?(Map.values(ctx), &is_binary/1)

    # Every variable the template declares is a key this context carries.
    descriptor =
      Platform.Orchestration.PromptTemplates.default_templates()
      |> Enum.find(&(&1.slug == "hr.profile.v1"))

    supplied = ctx |> Map.keys() |> Enum.map(&to_string/1)
    assert descriptor.variables -- supplied == []

    assert {:ok, %{system: system, user: user}} = Hr.build_prompt(ctx)
    assert system =~ "You are HR"
    assert user =~ "You are HR"
    assert user =~ "I prefer small PRs"
    refute user =~ "{{"
  end

  test "gather_context for a meeting carries participants and the subject's own words, never another speaker's remark" do
    marisol = user!("Marisol Tennebrook")
    space = space!()
    room = room!(space)
    transcript = transcript!(room, space)

    # Only Marisol sat in the room as a participant; the founder's remark is
    # in the transcript but is nobody's own words here.
    {:ok, _} =
      Meetings.participant_joined(room, %{
        display_name: "Marisol Tennebrook",
        joined_at: DateTime.add(@now, -25, :minute),
        user_id: marisol.id
      })

    ctx_in = %{
      kind: :event_topic,
      topic: "meeting:finished",
      payload: %{
        transcript_id: transcript.id,
        room_id: room.livekit_room_name,
        space_id: space.id
      }
    }

    assert {:ok, ctx} = Hr.gather_context(responsibility("hr.meeting_completed"), ctx_in)

    assert ctx.people_appearances =~ "Marisol Tennebrook [human] via meeting_participant"
    assert ctx.people_own_words =~ "### Marisol Tennebrook (new)"
    assert ctx.people_own_words =~ "I will own the pipeline"
    assert ctx.people_own_words =~ "[cite: meeting:transcript:#{transcript.id}:s2]"
    refute ctx.people_own_words =~ @others_spoken
    refute ctx.people_own_words =~ "slow playing"
    # Scrubbed before the model sees it.
    refute ctx.people_own_words =~ "904-555-0100"
    # The summary is never read.
    refute ctx.people_own_words =~ "doubted"

    # The meeting row leaves no sweep signal behind.
    assert hr_rows(nil) == []

    assert {:error, :transcript_not_found} =
             Hr.gather_context(responsibility("hr.meeting_completed"), %{
               kind: :event_topic,
               payload: %{transcript_id: Ecto.UUID.generate()}
             })
  end

  # ── handle_output ────────────────────────────────────────────────────────

  test "handle_output writes card and private profile, regenerates the index and journals a finished row naming the paths" do
    parent = self()
    ref = make_ref()

    :telemetry.attach(
      "hr-test-#{inspect(ref)}",
      [:platform, :people, :curated],
      fn _event, measurements, _meta, _ -> send(parent, {:curated, measurements}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("hr-test-#{inspect(ref)}") end)

    output = %{"people" => [profile("Marisol Tennebrook")], "review" => []}

    assert :ok =
             Hr.handle_output(responsibility("hr.daily_sweep"), output, %{
               kind: :cron,
               agent_id: @agent_id
             })

    card_path = Visibility.card_path("marisol-tennebrook")
    private_path = Visibility.private_path("marisol-tennebrook")

    card = page(card_path)
    assert card.content =~ "tier: card"
    assert card.content =~ "name: Marisol Tennebrook"
    assert card.content =~ "deploy pipeline"
    refute card.content =~ "## Perspectives"
    refute card.content =~ "## Interactions"
    assert card.updated_by == @agent_id

    private = page(private_path)
    assert private.content =~ "tier: private"
    assert private.content =~ "readers: [subject, admins]"
    assert private.content =~ "subject_user_id: #{@subject_user_id}"

    assert private.content =~
             "2026-10-20 meeting: Deploy review [cite: meeting:transcript:abc:s2]"

    assert private.content =~
             "I will own the pipeline — own words [cite: meeting:transcript:abc:s2]"

    assert private.updated_by == @agent_id

    index = page(Visibility.index_path())
    assert index.content =~ "**Marisol Tennebrook** [[#{card_path}]]"

    [finished] = hr_rows("finished")
    assert finished.content =~ "HR daily sweep finished"
    assert finished.content =~ card_path
    assert finished.content =~ private_path
    assert finished.metadata["updated"] == [card_path, private_path]
    assert {:finished, _} = SweepState.status(DateTime.utc_now())

    assert_receive {:curated, %{written: 2, ambiguous: 0, review: 0, dropped_others_said: 0}}

    # The meeting key writes the same pages but no sweep row.
    Repo.delete_all(WikiJournalEntry)

    assert :ok =
             Hr.handle_output(responsibility("hr.meeting_completed"), output, %{
               kind: :event_topic,
               agent_id: @agent_id
             })

    assert hr_rows(nil) == []
  end

  test "handle_output drops an others-said perspective and a trait judgement but keeps the meeting row" do
    output = %{
      "people" => [
        profile("Marisol Tennebrook", %{
          "perspectives" => [
            %{
              "statement" => "I will own the pipeline",
              "said_by_subject" => true,
              "citation" => "meeting:transcript:abc:s2"
            },
            %{
              "statement" => "Marisol is slow playing the deploy",
              "said_by_subject" => false,
              "citation" => "meeting:transcript:abc:s1"
            },
            %{
              "statement" => "I am clearly brilliant at this",
              "said_by_subject" => true,
              "citation" => "meeting:transcript:abc:s3"
            }
          ]
        })
      ]
    }

    assert :ok = Hr.handle_output(responsibility("hr.daily_sweep"), output, %{kind: :cron})

    private = page(Visibility.private_path("marisol-tennebrook"))
    assert private.content =~ "2026-10-20 meeting: Deploy review"
    assert private.content =~ "I will own the pipeline — own words"
    refute private.content =~ "slow playing"
    refute private.content =~ "brilliant"

    card = page(Visibility.card_path("marisol-tennebrook"))
    refute card.content =~ "slow playing"
    refute card.content =~ "brilliant"
    refute card.content =~ "Deploy review"
  end

  test "handle_output writes nothing for an ambiguous profile and journals it" do
    card!("priya-kalloway", "Priya Kalloway")
    card!("priya-vellinghausen", "Priya Vellinghausen")
    before = Repo.all(WikiPage) |> Enum.map(&{&1.file_key, &1.version}) |> Enum.sort()

    output = %{
      "people" => [profile("Priya")],
      "review" => ["Fixture Founder: no card, no account"]
    }

    assert :ok =
             Hr.handle_output(responsibility("hr.daily_sweep"), output, %{
               kind: :cron,
               agent_id: @agent_id
             })

    after_ = Repo.all(WikiPage) |> Enum.map(&{&1.file_key, &1.version}) |> Enum.sort()
    assert after_ == before
    assert page(Visibility.private_path("priya-kalloway")) == nil
    assert page(Visibility.private_path("priya-vellinghausen")) == nil
    assert page(Visibility.card_path("priya")) == nil

    [review] = WikiJournalEntry |> Repo.all() |> Enum.filter(&(&1.metadata["phase"] == "review"))
    assert review.content =~ "ambiguous: \"Priya\" could be priya-kalloway or priya-vellinghausen"
    assert review.content =~ "Fixture Founder: no card, no account"

    [finished] = hr_rows("finished")
    assert finished.content =~ "updated none"
  end

  test "two spellings in one output resolve to one slug" do
    output = %{
      "people" => [
        profile("Oskar Vellinghausen", %{
          "current_projects" => ["billing"],
          "perspectives" => [
            %{
              "statement" => "I like invoices",
              "said_by_subject" => true,
              "citation" => "chat:a:1"
            }
          ]
        }),
        profile("Oskar Velinghausen", %{
          "current_projects" => ["deploy pipeline"],
          "perspectives" => [
            %{
              "statement" => "I dislike long builds",
              "said_by_subject" => true,
              "citation" => "chat:a:2"
            }
          ]
        })
      ]
    }

    assert :ok = Hr.handle_output(responsibility("hr.daily_sweep"), output, %{kind: :cron})

    people_paths =
      Repo.all(WikiPage)
      |> Enum.map(& &1.file_key)
      |> Enum.filter(&String.starts_with?(&1, Visibility.prefix()))
      |> Enum.sort()

    assert people_paths == [
             Visibility.index_path(),
             Visibility.card_path("oskar-vellinghausen"),
             Visibility.private_path("oskar-vellinghausen")
           ]

    private = page(Visibility.private_path("oskar-vellinghausen"))
    assert private.content =~ "- billing"
    assert private.content =~ "- deploy pipeline"
    assert private.content =~ "I like invoices — own words"
    assert private.content =~ "I dislike long builds — own words"

    [finished] = hr_rows("finished")

    assert finished.metadata["updated"] == [
             Visibility.card_path("oskar-vellinghausen"),
             Visibility.private_path("oskar-vellinghausen")
           ]
  end

  test "handle_refusal journals a finished row for the daily sweep only" do
    assert :ok =
             Hr.handle_refusal(
               responsibility("hr.daily_sweep"),
               {:context_gather_refused, :nothing_to_curate},
               %{kind: :cron}
             )

    [finished] = hr_rows("finished")
    assert finished.content =~ "updated none (refused:"

    Repo.delete_all(WikiJournalEntry)

    assert :ok =
             Hr.handle_refusal(
               responsibility("hr.meeting_completed"),
               {:context_gather_refused, :transcript_not_found},
               %{kind: :event_topic}
             )

    assert hr_rows(nil) == []
  end

  test "the handler never calls Router.fire" do
    source = File.read!(Path.join(File.cwd!(), "lib/platform/responsibilities/handlers/hr.ex"))
    refute source =~ "Router.fire"
    refute source =~ "Responsibilities.Router"
    refute source =~ "DreamingPasses."
    refute source =~ ":ets"
    refute source =~ "GenServer"
  end
end
