defmodule Platform.Meetings.OpenQuestionPilot.ScoreTest do
  @moduledoc """
  `OpenQuestionPilot.Score` (task 01a0e8b5 stage 2): precision/recall with
  error classes kept out of the labels, latency, tokens and stated cost, and
  the privacy check at both levels, the artefact level through the real
  handlers' `gather_context/2` in a meeting with no canvas (the method of
  `scribe_misfire_rate_test.exs`). No network.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Meetings
  alias Platform.Meetings.OpenQuestionPilot.Meter
  alias Platform.Meetings.OpenQuestionPilot.Program
  alias Platform.Meetings.OpenQuestionPilot.Score
  alias Platform.Roles

  defmodule ScriptedProvider do
    @moduledoc false
    # Arm A answers from :pilot_script, a map of chunk => intent (default
    # off_topic) or chunk => :garbage. Arm B answers from :pilot_b_script,
    # chunk => true | false. Quotes are the whole chunk.
    def chat(_credentials, messages, _opts) do
      system = Enum.find_value(messages, "", &(&1.role == "system" && &1.content))
      user = Enum.find_value(messages, "", &(&1.role == "user" && &1.content))

      content =
        if system == "system prompt" do
          case Map.get(Process.get(:pilot_script, %{}), user, "off_topic") do
            :garbage ->
              "not json at all"

            intent ->
              Jason.encode!(%{
                "intent" => intent,
                "target_role" => nil,
                "confidence" => 0.9,
                "evidence_quote" => if(intent == "off_topic", do: "", else: user)
              })
          end
        else
          b = Process.get(:pilot_b_script, %{})

          answer =
            Enum.find_value(b, false, fn {chunk, v} -> String.contains?(user, chunk) && v end)

          "[[ ## is_question ## ]]\n#{answer}\n\n[[ ## addressee ## ]]\nnone\n\n[[ ## completed ## ]]"
        end

      {:ok,
       %{
         content: content,
         finish_reason: "stop",
         usage: %{"prompt_tokens" => 50, "completion_tokens" => 5}
       }}
    end
  end

  setup do
    Repo.insert!(
      %Platform.Roles.Role{
        key: "meeting_scribe",
        name: "Meeting Scribe",
        description: "open_question pilot",
        icon: "hero-star"
      },
      on_conflict: :nothing,
      conflict_target: :key
    )

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "pilot-scribe-#{System.unique_integer([:positive])}",
        name: "Quill",
        status: "active"
      })
      |> Repo.insert!()

    {:ok, _} = Roles.assign_role("meeting_scribe", agent.id)

    {:ok, project} =
      Platform.Tasks.create_project(%{name: "Pilot #{System.unique_integer([:positive])}"})

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Pilot"})
    {:ok, room_space} = Platform.Chat.create_space(%{kind: "execution"})

    room =
      %Meetings.Room{}
      |> Meetings.Room.changeset(%{
        space_id: room_space.id,
        livekit_room_name: "space:#{room_space.id}"
      })
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

    on_exit(fn ->
      Process.delete(:pilot_script)
      Process.delete(:pilot_b_script)
    end)

    base_args = %{
      provider_module: ScriptedProvider,
      agent: %{model: "stub"},
      prompt: "system prompt",
      room_id: room.id,
      roster: Roles.assigned_agents(),
      participants: Meetings.active_participants(room.id)
    }

    %{
      base_args: base_args,
      check: Score.gather_context_check(meeting.id, room.id),
      meter: Meter.new(cap: 1_000, live_module: ScriptedProvider)
    }
  end

  defp row(id, text, opts \\ []) do
    %{
      "id" => id,
      "text" => text,
      "participants" => ["Priya", "Dana", "Marcus"],
      "is_question" => Keyword.get(opts, :q, false),
      "addressee" => "none",
      "shape" => "s",
      "privacy" => Keyword.get(opts, :privacy, false),
      "origin" => "synthesised",
      "provenance" => "test",
      "split" => "test"
    }
  end

  defp score(rows, arm, ctx, opts \\ []) do
    {report, _log} =
      with_log(fn ->
        Score.run(
          rows,
          arm,
          Keyword.merge(
            [base_args: ctx.base_args, meter: ctx.meter, artefact_check: ctx.check],
            opts
          )
        )
      end)

    report
  end

  @priya "Priya to deliver list of demands to Marcus by end of week"

  describe "privacy, at both levels" do
    test "a routable candid row the floor refuses counts at level (i) and NOT at level (ii)",
         ctx do
      Process.put(:pilot_script, %{@priya => "action_items"})

      report = score([row("p1", @priya, privacy: true)], :prompt, ctx)

      assert report.privacy.rows == 1
      assert report.privacy.output_routable == 1
      assert report.privacy.artefact_checked == 1
      assert report.privacy.artefact_not_refused == 0
      refute report.privacy.ok?
    end

    test "a candid row that gets past gather_context counts at level (ii)", ctx do
      Process.put(:pilot_script, %{@priya => "open_question"})

      report =
        score([row("p1", @priya, privacy: true)], :prompt, ctx,
          artefact_check: fn _row, _decision -> :not_refused end
        )

      assert report.privacy.output_routable == 1
      assert report.privacy.artefact_not_refused == 1
      refute report.privacy.ok?
    end

    test "a routable privacy row under an intent outside level (i) is still checked at level (ii)",
         ctx do
      Process.put(:pilot_script, %{@priya => "brief_worthy"})

      report = score([row("p1", @priya, privacy: true)], :prompt, ctx)

      assert report.privacy.output_routable == 0
      assert report.privacy.artefact_checked == 1
      assert report.privacy.artefact_not_refused == 0
    end

    test "a declined privacy row is clean at both levels", ctx do
      report = score([row("p1", @priya, privacy: true)], :prompt, ctx)

      assert report.privacy == %{
               rows: 1,
               output_routable: 0,
               artefact_checked: 0,
               artefact_not_refused: 0,
               ok?: true
             }
    end

    test "arm B promoting a candid question is caught at level (i)", ctx do
      text = "Did Teodor ever hear back about his pay review?"
      Process.put(:pilot_b_script, %{text => true})

      report =
        score([row("p2", text, privacy: true, q: true)], {:imp_program, Program.new()}, ctx)

      assert report.privacy.output_routable == 1
      assert report.privacy.artefact_checked == 1
    end
  end

  describe "labels, errors, latency, cost" do
    test "precision and recall over decided rows; errors counted apart", ctx do
      Process.put(:pilot_script, %{
        "Which region first?" => "open_question",
        "The pilot starts Monday, doesn't it?" => "open_question",
        "Should the export ship behind a flag?" => "off_topic",
        "Where does the checklist live?" => :garbage
      })

      rows = [
        row("tp", "Which region first?", q: true),
        row("fp", "The pilot starts Monday, doesn't it?"),
        row("fn", "Should the export ship behind a flag?", q: true),
        row("tn", "Dana to send the notes by Friday"),
        row("err", "Where does the checklist live?", q: true)
      ]

      report = score(rows, :prompt, ctx)

      assert report.n == 5
      assert report.scored == 4
      assert report.confusion == %{tp: 1, fp: 1, fn: 1, tn: 1}
      assert report.precision == 0.5
      assert report.recall == 0.5

      assert report.errors == %{
               parse_error: 1,
               empty_output: 0,
               model_error: 0,
               budget_exhausted: 0
             }

      assert Enum.find(report.rows, &(&1.id == "err")).error == :parse_error
    end

    test "arm B's labels come from decide/3 and its demotions are visible", ctx do
      Process.put(:pilot_script, %{
        "Which region first?" => "open_question",
        "The pilot starts Monday, doesn't it?" => "open_question"
      })

      Process.put(:pilot_b_script, %{"Which region first?" => true})

      rows = [
        row("tp", "Which region first?", q: true),
        row("tn", "The pilot starts Monday, doesn't it?")
      ]

      report = score(rows, {:imp_program, Program.new()}, ctx)

      assert report.arm == "imp_program"
      assert report.confusion == %{tp: 1, fp: 0, fn: 0, tn: 1}
      assert Enum.find(report.rows, &(&1.id == "tn")).demotion_reason == :imp_not_question
    end

    test "latency, tokens and a stated zero cost", ctx do
      Process.put(:pilot_script, %{"Which region first?" => "off_topic"})

      report =
        score([row("a", "Which region first?", q: true)], {:imp_program, Program.new()}, ctx)

      assert report.lm_calls == 2
      assert report.tokens == %{prompt: 100, completion: 10, total: 110}
      assert report.cost_usd == 0.0
      assert report.cost_basis =~ "self-hosted"
      assert report.latency.chunk.n == 1
      assert report.latency.lm_call.n == 2

      assert Map.keys(report.latency.lm_call_by_purpose) |> Enum.sort() == [
               :imp_program,
               :prompt_arm
             ]

      priced =
        score([row("a", "Which region first?", q: true)], :prompt, ctx,
          price_per_1k_tokens: 2.0,
          cost_basis: "hosted"
        )

      assert priced.cost_usd == 55 / 1000 * 2.0
    end

    test "nearest-rank percentiles" do
      assert Score.percentiles([]) == %{p50: nil, p95: nil, n: 0}
      assert Score.percentiles(Enum.to_list(1..20)) == %{p50: 10, p95: 19, n: 20}
      assert Score.percentiles([7]) == %{p50: 7, p95: 7, n: 1}
    end
  end
end
