defmodule Platform.Meetings.ScribeMisfireRateTest do
  @moduledoc """
  The surviving false-positive rate of the deterministic meeting-intent
  gates over `Platform.Meetings.ScribeMisfireCorpus` (task `01a0e58f`,
  acceptance 5).

  ## Method

  Every row goes through `IntentClassifier.decide/1` driven by an
  ALWAYS-FIRE stub model: it returns the row's tagged misfire intent at
  0.95 with the whole row as `evidence_quote`. That is the worst case the
  gates can face, and it is why the number measures the gates and not a
  model. A row still routable after `decide/1` (its intent is not
  `off_topic`; a nulled role is still routable, because the dispatcher
  forks on the responsibility first) then goes through its handler's
  `gather_context/2` in a meeting whose space holds no canvas, which runs
  the privacy floor and the near-miss check.

  A row SURVIVES iff it stays routable AND `gather_context/2` returns
  `{:ok, _}`.

  The printed line carries its window and n. It is a synthetic-corpus
  number with an always-fire stub, NOT a production measurement.

  `@surviving_fp` and `@survivors_by_shape` are pinned so any change to
  the gates or the corpus that moves the number is deliberate.

  ## The measurement, as first recorded (e86a2fca)

      scribe misfire corpus: surviving FP 25/35 (71.4%), positives
      surviving 10/10, privacy refused 5/5 — synthetic corpus, n=35
      negatives, always-fire stub model; NOT a production measurement

  All three named causes (reported speech with an absent vocative, a
  speech-act label, a quoted genre) are stopped, all 10 positives
  survive, and all 5 candid rows are refused by the privacy floor.

  ## What the gates do not reach

  The gates are lexical and scoped to named operators, so a shape with no
  operator in any lexicon passes whole:

    * **tag_question 5/5 survive.** "..., didn't we?" seeks agreement
      with something already said. No lexicon names a tag, and the
      quoted-label rule needs a head noun after the `?`.
    * **fragment 5/5 survive**, including the real specimen "Is this a
      demo? No, this is the…". A fragment has no predicate for any frame
      to scope.
    * **hypothetical_conditional 4/5 survive.** Only the row that also
      delegates to "someone" is caught; "if", "suppose" and "were we to"
      are not operators.
    * **pseudo_cleft 3/5, embedded_wh 3/5, imperative 3/5,
      quotation_as_modifier 2/5 survive.** Caught rows are the ones that
      also carry a speech-act label, first-person doubt about a taxonomy
      label, a retraction, a delegation, or a quoted QUESTION followed by
      a head noun. A quoted phrase without a `?` ("let's just ship it"
      vibe) is not caught, and neither is a name inside a pseudo-cleft
      ("What Tobias wants is ...") because it is not a vocative.
    * "Write my strategy", the other real specimen, survives.

  The near-miss check adds no refusals here: with the whole row as the
  model's quote, `decide/1` has already asked the same frame and
  addressee questions. Its reach is the case where the model quotes a
  narrower span than the excerpt.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Meetings
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.ScribeMisfireCorpus, as: Corpus
  alias Platform.Responsibilities.Handlers.MeetingActionItems
  alias Platform.Responsibilities.Handlers.MeetingBriefWorthy
  alias Platform.Responsibilities.Handlers.MeetingOpenQuestion
  alias Platform.Responsibilities.Responsibility
  alias Platform.Roles

  # Measured at e86a2fca on the test-host rig. See "What the gates do not
  # reach" in the moduledoc before moving either pin.
  @surviving_fp 25
  @survivors_by_shape %{
    pseudo_cleft: 3,
    embedded_wh: 3,
    tag_question: 5,
    hypothetical_conditional: 4,
    imperative: 3,
    fragment: 5,
    quotation_as_modifier: 2
  }

  defmodule AlwaysFireProvider do
    @moduledoc false
    # Reads the row's misfire intent out of the calling process, which is
    # the test process: `decide/1` is called inline.
    def chat(_credentials, _messages, _opts) do
      {intent, text} = Process.get(:scribe_misfire_row)

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "intent" => intent,
             "target_role" => "meeting_scribe",
             "confidence" => 0.95,
             "evidence_quote" => text
           })
       }}
    end
  end

  @handlers %{
    "action_items" => MeetingActionItems,
    "brief_worthy" => MeetingBriefWorthy,
    "open_question" => MeetingOpenQuestion
  }

  setup do
    Repo.insert!(
      %Platform.Roles.Role{
        key: "meeting_scribe",
        name: "Meeting Scribe",
        description: "misfire corpus",
        icon: "hero-star"
      },
      on_conflict: :nothing,
      conflict_target: :key
    )

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "misfire-scribe-#{System.unique_integer([:positive])}",
        name: "Quill",
        status: "active"
      })
      |> Repo.insert!()

    {:ok, _} = Roles.assign_role("meeting_scribe", agent.id)

    {:ok, project} =
      Platform.Tasks.create_project(%{name: "Misfire #{System.unique_integer([:positive])}"})

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "One to one"})

    {:ok, room_space} = Platform.Chat.create_space(%{kind: "execution"})

    room =
      %Meetings.Room{}
      |> Meetings.Room.changeset(%{
        space_id: room_space.id,
        livekit_room_name: "space:#{room_space.id}"
      })
      |> Repo.insert!()

    for name <- Corpus.participant_names() do
      %Meetings.Participant{}
      |> Meetings.Participant.changeset(%{
        room_id: room.id,
        display_name: name,
        joined_at: DateTime.utc_now()
      })
      |> Repo.insert!()
    end

    on_exit(fn -> Process.delete(:scribe_misfire_row) end)

    %{meeting: meeting, room: room, roster: Roles.assigned_agents()}
  end

  # :survived | {:demoted, reason} | {:refused, reason}
  defp run_row({_shape, intent, text}, %{meeting: meeting, room: room, roster: roster}) do
    Process.put(:scribe_misfire_row, {intent, text})
    participants = Meetings.active_participants(room.id)

    {:ok, decision} =
      IntentClassifier.decide(%{
        provider_module: AlwaysFireProvider,
        agent: %{model: "always-fire-stub"},
        prompt: "system prompt",
        chunk_text: text,
        room_id: room.id,
        roster: roster,
        participants: participants
      })

    if decision.intent == "off_topic" do
      {:demoted, decision.demotion_reason}
    else
      handler = Map.fetch!(@handlers, decision.intent)

      meta = %{
        kind: :event_topic,
        payload: %{
          intent_id: Platform.Types.UUIDv7.generate(),
          meeting_id: meeting.id,
          room_id: room.id,
          chunk_excerpt: text,
          classified_intent: decision.intent,
          confidence: decision.confidence,
          speaker: nil
        }
      }

      case handler.gather_context(%Responsibility{key: handler.key()}, meta) do
        {:ok, _ctx} -> :survived
        {:error, reason} -> {:refused, reason}
      end
    end
  end

  defp outcomes(rows, ctx) do
    {result, _log} = with_log(fn -> Enum.map(rows, &{&1, run_row(&1, ctx)}) end)
    result
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "--short=8", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp pct(k, n), do: :erlang.float_to_binary(k * 100 / n, decimals: 1)

  test "the surviving false-positive rate, with its window and n", ctx do
    negatives = Corpus.negatives()
    n = length(negatives)
    assert n == 35

    k = negatives |> outcomes(ctx) |> Enum.count(fn {_row, o} -> o == :survived end)

    positives = Corpus.positives()
    p_total = length(positives)
    positive_outcomes = outcomes(positives, ctx)
    p = Enum.count(positive_outcomes, fn {_row, o} -> o == :survived end)

    privacy = Corpus.privacy()
    r_total = length(privacy)
    privacy_outcomes = outcomes(privacy, ctx)
    r = Enum.count(privacy_outcomes, fn {_row, o} -> o == {:refused, :candid_register} end)

    IO.puts(
      "scribe misfire corpus: surviving FP #{k}/#{n} (#{pct(k, n)}%), " <>
        "positives surviving #{p}/#{p_total}, privacy refused #{r}/#{r_total} — " <>
        "window: synthetic corpus Platform.Meetings.ScribeMisfireCorpus at #{git_sha()}, " <>
        "n=#{n} negatives, always-fire stub model; NOT a production measurement"
    )

    assert p_total >= 10
    assert r_total >= 5

    assert p == p_total,
           "a genuine ask was suppressed: #{inspect(for {row, o} <- positive_outcomes, o != :survived, do: {row, o})}"

    assert r == r_total,
           "a candid row was not refused by the floor: #{inspect(for {row, o} <- privacy_outcomes, o != {:refused, :candid_register}, do: {row, o})}"

    assert k == @surviving_fp
  end

  test "every named cause is stopped", ctx do
    for {row, outcome} <- outcomes(Corpus.causes(), ctx) do
      refute outcome == :survived, "cause row survived: #{inspect(row)}"
    end
  end

  test "survivors per shape — what the gates do not reach", ctx do
    all = outcomes(Corpus.negatives(), ctx)

    by_shape =
      all
      |> Enum.filter(fn {_row, o} -> o == :survived end)
      |> Enum.frequencies_by(fn {{shape, _intent, _text}, _o} -> shape end)

    # Every row's fate, so the report can name WHICH gate stopped what.
    # The rows are synthetic; printing them discloses nothing.
    for {{shape, _intent, text}, outcome} <- all do
      IO.puts("  #{shape}: #{inspect(outcome)} — #{text}")
    end

    IO.puts(
      "scribe misfire corpus survivors by shape: " <>
        Enum.map_join(Corpus.shapes(), ", ", &"#{&1}=#{Map.get(by_shape, &1, 0)}/5")
    )

    assert Enum.all?(Corpus.shapes(), fn shape ->
             Enum.count(Corpus.negatives(), &(elem(&1, 0) == shape)) == 5
           end)

    assert by_shape == @survivors_by_shape
  end
end
