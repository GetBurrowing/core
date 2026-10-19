defmodule Platform.Meetings.IntentClassifierOpenQuestionArmTest do
  @moduledoc """
  The open_question arm at `IntentClassifier`'s read point (task 01a0e8b5
  stage 3). The arm is DATA: with no experiment the classifier behaves as it
  did before the surface existed (one provider call, the same messages); a
  running experiment with an `imp_program` variant sends a meeting through
  the Imp program; a stop keeps assigned meetings where they are; a muted
  meeting is never assigned; and privacy stays a hard floor under the imp
  arm. No network: the provider is a stub, and arm B rides it through
  `OpenQuestionPilot.ProviderLM` exactly as it would ride Ollama.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Experiments
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Variant
  alias Platform.Meetings
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.OpenQuestionPilot.Meter
  alias Platform.Meetings.OpenQuestionPilot.Programs
  alias Platform.Meetings.OpenQuestionPilot.Score
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Roles

  @surface "meetings.open_question_classifier"
  @target "meetings.intent_classify"
  @b_true "[[ ## is_question ## ]]\ntrue\n\n[[ ## addressee ## ]]\nnone\n\n[[ ## completed ## ]]"

  defmodule Stub do
    @moduledoc false
    # Reads its behaviour from the CALLING process's dictionary (the test
    # process for direct calls, the classifier's for broadcast ones).
    def chat(credentials, messages, opts) do
      # The classifier's test seam plants under :intent_classifier_stub_fun.
      case Process.get(:oq_arm_stub) || Process.get(:intent_classifier_stub_fun) do
        nil -> {:error, :no_stub}
        fun -> fun.(credentials, messages, opts)
      end
    end
  end

  setup do
    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "oq-arm-#{System.unique_integer([:positive])}",
        name: "OQ Arm",
        status: "active"
      })
      |> Repo.insert!()

    {:ok, _} = Roles.set_override("meetings.intent_classify", agent.id)

    handler = "oq-arm-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler,
      [
        [:platform, :meetings, :intent_classified],
        [:platform, :meetings, :intent_classifier, :arm_unavailable]
      ],
      fn event, _m, meta, _ -> send(test_pid, {:telemetry, List.last(event), meta}) end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      Process.delete(:oq_arm_stub)
    end)

    %{agent: agent}
  end

  # A stub: arm A answers `a_intent` citing the chunk; arm B (recognisable
  # by Imp's field markers) answers `b_reply`. Every call is reported.
  defp stub_fun(test_pid, a_intent, b_reply \\ @b_true) do
    fn _credentials, messages, opts ->
      user = Enum.find_value(messages, "", &(to_string(&1.role) == "user" && &1.content))
      arm = if String.contains?(user, "[[ ## excerpt ## ]]"), do: :b, else: :a
      send(test_pid, {:provider_called, arm, messages, opts})

      content =
        case arm do
          :b ->
            b_reply

          :a ->
            Jason.encode!(%{
              "intent" => a_intent,
              "target_role" => nil,
              "confidence" => 0.9,
              "evidence_quote" => if(a_intent == "off_topic", do: "", else: user)
            })
        end

      {:ok, %{content: content, finish_reason: "stop", usage: %{}}}
    end
  end

  defp payload(meeting_id, text) do
    %{
      room_id: "room-oq-#{System.unique_integer([:positive])}",
      meeting_id: meeting_id,
      transcript_id: "transcript-#{System.unique_integer([:positive])}",
      segment: %{
        id: "seg-#{System.unique_integer([:positive])}",
        text: text,
        speaker_name: "alice"
      }
    }
  end

  defp classify!(agent, meeting_id, text) do
    on_exit(fn -> IntentQueue.stop(meeting_id) end)

    {:ok, _log} =
      with_log(fn ->
        IntentClassifier.classify_and_enqueue(payload(meeting_id, text), agent, [], %{
          provider_module: Stub
        })
      end)

    :ok
  end

  defp provider_calls do
    receive do
      {:provider_called, arm, messages, opts} -> [{arm, messages, opts} | provider_calls()]
    after
      0 -> []
    end
  end

  # `baseline_v0.json` is the UNOPTIMISED baseline Imp program
  # (`OpenQuestionPilot.Program.new/0`, no demos). It exercises the
  # imp_program arm's MECHANICS; it is not "B" (stage 4 found no admissible
  # optimised B, so no program_b.json exists).
  defp running_imp_experiment!(program \\ "baseline_v0.json", extra \\ %{}) do
    {:ok, experiment} =
      Experiments.create_experiment(
        Map.merge(
          %{
            slug: "oq-arm-#{System.unique_integer([:positive])}",
            name: "open_question arm",
            surface_key: @surface,
            surface_target: @target
          },
          extra
        )
      )

    {:ok, _} =
      Experiments.add_variant(experiment, %{
        slug: "imp",
        payload: %{"arm" => "imp_program", "program" => program},
        weight: 1
      })

    {:ok, %Experiment{status: "running"} = running} =
      Experiments.start(experiment, Platform.TenancyFixtures.root_admin!())

    # Every new meeting goes to the imp arm.
    Repo.update_all(
      from(v in Variant,
        where: v.experiment_id == ^running.id and v.slug == ^Experiment.control_slug()
      ),
      set: [weight: 0]
    )

    running
  end

  defp assignments(meeting_id) do
    Repo.all(
      from(a in Assignment, where: a.subject_type == "meeting" and a.subject_id == ^meeting_id)
    )
  end

  test "nothing is seeded: no experiment exists on the surface" do
    assert Repo.all(from(e in Experiment, where: e.surface_key == ^@surface)) == []
  end

  describe "no experiment" do
    test "the prompt arm: exactly one provider call, the same messages decide/1 sends", ctx do
      Process.put(:oq_arm_stub, stub_fun(self(), "open_question"))
      meeting_id = Ecto.UUID.generate()
      text = "Which region do we roll the beta out to first?"

      classify!(ctx.agent, meeting_id, text)

      assert [{:a, messages, opts}] = provider_calls()
      assert [%{role: "system", content: prompt}, %{role: "user", content: ^text}] = messages
      assert is_binary(prompt) and prompt != ""

      assert opts == [
               temperature: 0.0,
               max_tokens: 1024,
               chat_template_kwargs: %{"enable_thinking" => false}
             ]

      # The read point hands decide/1 what it always did: the same prompt,
      # sent directly, gives the byte-identical provider input.
      {{:ok, _}, _} =
        with_log(fn ->
          IntentClassifier.decide(%{
            provider_module: Stub,
            agent: ctx.agent,
            prompt: prompt,
            chunk_text: text,
            room_id: nil
          })
        end)

      assert [{:a, ^messages, ^opts}] = provider_calls()

      assert_received {:telemetry, :intent_classified, meta}
      assert meta.arm == "prompt"
      assert meta.experiment_id == nil
      assert meta.intent == "open_question"
      assert assignments(meeting_id) == []
    end
  end

  describe "a running imp_program experiment" do
    test "sends the meeting through the Imp program and tags the event", ctx do
      experiment = running_imp_experiment!()
      Process.put(:oq_arm_stub, stub_fun(self(), "off_topic"))
      meeting_id = Ecto.UUID.generate()

      classify!(ctx.agent, meeting_id, "Should the export feature ship behind a flag?")

      assert [{:a, _, a_opts}, {:b, b_messages, b_opts}] = provider_calls()
      assert a_opts == b_opts

      assert Enum.any?(
               b_messages,
               &(&1.content =~ "Should the export feature ship behind a flag?")
             )

      assert_received {:telemetry, :intent_classified, meta}
      assert meta.arm == "imp_program"
      assert meta.experiment_id == experiment.id
      # A said off_topic, B said it is a question: promoted.
      assert meta.intent == "open_question"

      assert [%Assignment{variant_slug: "imp"}] = assignments(meeting_id)
    end

    test "a stop keeps an assigned meeting on its arm; a new meeting gets the control", ctx do
      experiment = running_imp_experiment!()
      Process.put(:oq_arm_stub, stub_fun(self(), "off_topic"))
      assigned = Ecto.UUID.generate()

      classify!(ctx.agent, assigned, "Which region do we roll the beta out to first?")
      assert [{:a, _, _}, {:b, _, _}] = provider_calls()
      assert_received {:telemetry, :intent_classified, %{arm: "imp_program"}}

      {:ok, %Experiment{status: "stopped"}} = Experiments.stop(experiment)

      classify!(ctx.agent, assigned, "When does the design freeze actually happen?")
      assert [{:a, _, _}, {:b, _, _}] = provider_calls()
      assert_received {:telemetry, :intent_classified, %{arm: "imp_program"} = meta}
      assert meta.experiment_id == experiment.id

      fresh = Ecto.UUID.generate()
      classify!(ctx.agent, fresh, "Where should the onboarding checklist live?")
      assert [{:a, _, _}] = provider_calls()
      assert_received {:telemetry, :intent_classified, %{arm: "prompt", experiment_id: nil}}
      assert assignments(fresh) == []
    end

    test "a variant whose program became unreadable resolves to the prompt arm", ctx do
      experiment = running_imp_experiment!()
      Process.put(:oq_arm_stub, stub_fun(self(), "off_topic"))

      name = "zz_vanishing_#{System.unique_integer([:positive])}.json"
      path = Path.join(Programs.dir(), name)
      File.cp!(Path.join(Programs.dir(), "baseline_v0.json"), path)
      on_exit(fn -> File.rm(path) end)

      Repo.update_all(
        from(v in Variant, where: v.experiment_id == ^experiment.id and v.slug == "imp"),
        set: [payload: %{"arm" => "imp_program", "program" => name}]
      )

      # Corrupted after the variant was written: the resolver re-validates
      # the payload, refuses it, and falls through to the surface default
      # (none, so the control). It never raises into the read point.
      File.write!(path, "{}")
      meeting_id = Ecto.UUID.generate()

      classify!(ctx.agent, meeting_id, "Which region do we roll the beta out to first?")

      assert [{:a, _, _}] = provider_calls()
      assert_received {:telemetry, :intent_classified, %{arm: "prompt"}}
    end

    test "a promoted default whose program cannot load falls back to prompt, loudly", ctx do
      # A surface default is served WITHOUT re-validation, so this is the
      # path where the read point itself finds the program missing.
      Repo.insert!(
        Platform.Experiments.SurfaceDefault.changeset(%Platform.Experiments.SurfaceDefault{}, %{
          surface_key: @surface,
          surface_target: @target,
          seq: 1,
          kind: "promote",
          payload: %{"arm" => "imp_program", "program" => "gone_since_promotion.json"}
        })
      )

      Process.put(:oq_arm_stub, stub_fun(self(), "off_topic"))
      meeting_id = Ecto.UUID.generate()

      classify!(ctx.agent, meeting_id, "Which region do we roll the beta out to first?")

      assert [{:a, _, _}] = provider_calls()
      assert_received {:telemetry, :arm_unavailable, %{program: "gone_since_promotion.json"}}
      assert_received {:telemetry, :intent_classified, %{arm: "prompt", experiment_id: nil}}
    end
  end

  describe "an org-scoped experiment (the only kind a tenant-pinned scientist can make)" do
    test "assigns an in-org meeting to the imp arm and leaves an out-of-org meeting on prompt",
         ctx do
      org = Platform.TenancyFixtures.tenant_org_id("initech")
      other = Platform.TenancyFixtures.tenant_org_id("vandelay_ind")
      experiment = running_imp_experiment!("baseline_v0.json", %{org_id: org})
      assert experiment.org_id == org
      Process.put(:oq_arm_stub, stub_fun(self(), "off_topic"))

      {:ok, in_project} =
        Platform.Tasks.create_project(%{
          name: "OQ in #{System.unique_integer([:positive])}",
          org_id: org
        })

      {:ok, out_project} =
        Platform.Tasks.create_project(%{
          name: "OQ out #{System.unique_integer([:positive])}",
          org_id: other
        })

      {:ok, in_meeting} = Meetings.create_meeting(%{project_id: in_project.id, name: "in org"})

      {:ok, out_meeting} =
        Meetings.create_meeting(%{project_id: out_project.id, name: "out of org"})

      classify!(ctx.agent, in_meeting.id, "Should the export feature ship behind a flag?")
      assert [{:a, _, _}, {:b, _, _}] = provider_calls()
      assert_received {:telemetry, :intent_classified, %{arm: "imp_program"} = meta}
      assert meta.experiment_id == experiment.id
      assert [%Assignment{variant_slug: "imp"}] = assignments(in_meeting.id)

      classify!(ctx.agent, out_meeting.id, "Should the export feature ship behind a flag?")
      assert [{:a, _, _}] = provider_calls()
      assert_received {:telemetry, :intent_classified, %{arm: "prompt", experiment_id: nil}}
      assert assignments(out_meeting.id) == []
    end
  end

  test "a muted meeting is never assigned, and B is never asked", ctx do
    running_imp_experiment!()
    test_pid = self()

    {:ok, project} =
      Platform.Tasks.create_project(%{name: "OQ mute #{System.unique_integer([:positive])}"})

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Muted"})
    on_exit(fn -> IntentQueue.stop(meeting.id) end)
    {:ok, _} = Meetings.set_intent_muted(meeting, true)

    name = :"oq_arm_classifier_#{System.unique_integer([:positive])}"
    {:ok, pid} = start_supervised({IntentClassifier, provider_module: Stub, name: name})
    ref = make_ref()
    send(pid, {:__test_plant_stub, self(), ref, stub_fun(test_pid, "off_topic")})
    assert_receive {^ref, :ok}

    broadcast = fn text ->
      :ok =
        MeetingsPubSub.broadcast_transcript_chunk("room-oq-mute", %{
          payload(meeting.id, text)
          | room_id: "room-oq-mute"
        })
    end

    capture_log(fn ->
      broadcast.("Should we book the client workshop for next month or not?")
      refute_receive {:provider_called, _, _, _}, 500
      assert assignments(meeting.id) == []

      # Unmuted, the same pipeline assigns and asks B: the refute above
      # was not a dead harness.
      {:ok, _} = Meetings.set_intent_muted(meeting, false)
      broadcast.("Should we book the client workshop for next month or not?")
      assert_receive {:provider_called, :a, _, _}, 2_000
      assert_receive {:provider_called, :b, _, _}, 2_000
    end)

    assert [%Assignment{variant_slug: "imp"}] = assignments(meeting.id)
  end

  test "under the imp arm with an always-true B, the Priya line leaves no artefact", ctx do
    priya = "Priya to deliver list of demands to Marcus by end of week"

    {:ok, project} =
      Platform.Tasks.create_project(%{name: "OQ privacy #{System.unique_integer([:positive])}"})

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "One to one"})
    {:ok, space} = Platform.Chat.create_space(%{kind: "execution"})

    room =
      %Meetings.Room{}
      |> Meetings.Room.changeset(%{space_id: space.id, livekit_room_name: "space:#{space.id}"})
      |> Repo.insert!()

    for name <- ["Priya", "Dana", "Marcus"] do
      %Meetings.Participant{}
      |> Meetings.Participant.changeset(%{
        room_id: room.id,
        display_name: name,
        joined_at: DateTime.utc_now()
      })
      |> Repo.insert!()
    end

    Process.put(:oq_arm_stub, stub_fun(self(), "off_topic"))
    {:ok, program} = Programs.load("baseline_v0.json")

    row = %{
      "id" => "corpus-privacy-01",
      "text" => priya,
      "participants" => ["Priya", "Dana", "Marcus"],
      "is_question" => false,
      "privacy" => true,
      "addressee" => "none"
    }

    {report, _log} =
      with_log(fn ->
        Score.run([row], {:imp_program, program},
          base_args: %{
            provider_module: Stub,
            agent: ctx.agent,
            prompt: "system prompt",
            room_id: room.id,
            roster: Roles.assigned_agents(),
            participants: Meetings.active_participants(room.id)
          },
          meter: Meter.new(cap: 10, live_module: Stub),
          artefact_check: Score.gather_context_check(meeting.id, room.id)
        )
      end)

    # B was asked and said yes: the row IS routable as open_question, so the
    # floor, not the model, is what stops it.
    assert [%{imp: %{is_question: true}, intent: "open_question"}] = report.rows
    assert report.privacy.output_routable == 1
    assert report.privacy.artefact_checked == 1
    assert report.privacy.artefact_not_refused == 0
  end
end
