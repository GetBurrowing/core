defmodule Platform.Responsibilities.Handlers.MeetingIntentSpacePromptTest do
  @moduledoc """
  All six `meetings.*` mid-meeting intent prompts NAME the chat space
  their recipient writes into (2026-08-01, Alex's DM — no task behind it).

  ## What was wrong

  Every one of these bodies told a native agent to create or patch a
  canvas "in this meeting's space", and named no space. The value was
  already in hand and thrown away: `gather_context/2` calls
  `IntentContext.space_canvases(IntentContext.space_id(payload))`, whose
  return carries `:space_id` beside the inventory, and `prompt_assigns/1`
  called `format_canvases/1` — which renders the list and drops the id.

  `canvas_create` takes a `space_id`. A recipient that has not been told
  one either guesses or gives up. Traced on the production meeting
  `019fb8ec-8644-75a4-b764-cc859d082dce`.

  ## Why one file for six handlers

  The six differ in body and in artifact — `decision_recorded` writes the
  org journal rather than a canvas — but the plumbing under test is
  identical in all six and was copied between them. A per-handler file
  would be six copies of the same three assertions, and the failure mode
  worth catching is precisely "five were updated and the sixth was not",
  which only a table can see.

  ## Both render paths, deliberately

  The DB row is what production renders; the `@fallback_prompt` heredoc
  is what a rollout gap renders. A change made only in code never reaches
  a migrated database (PR #658's lesson), and a change made only in the
  migration leaves the fallback silently on the old behaviour. So each
  handler is asserted through both, and they are distinguishable: the DB
  path interpolates an unknown marker to `""` (silent), while the
  fallback's `substitute/2` leaves it literal — which is why `refute
  system =~ "{{"` is the fallback path's guard and a positive match on
  the id is the DB path's.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.IntentContext
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities.Handlers
  alias Platform.Responsibilities.Responsibility

  # {handler module, prompt slug}. Read from the handler's own
  # `template_slug/0` rather than restated, so a renamed slug cannot make
  # this file assert against a row nobody renders.
  @handlers [
    Handlers.MeetingActionItems,
    Handlers.MeetingOpenQuestion,
    Handlers.MeetingBriefWorthy,
    Handlers.MeetingDecisionRecorded,
    Handlers.MeetingVisualAdjust,
    Handlers.MeetingInteractionDesign
  ]

  defp responsibility(handler) do
    [spec] = handler.register()
    struct(Responsibility, Map.put(spec, :id, Ecto.UUID.generate()))
  end

  defp create_meeting! do
    {:ok, project} =
      Platform.Tasks.create_project(%{name: "Intent Space #{System.unique_integer([:positive])}"})

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Standup"})
    meeting
  end

  # The live shape `IntentDispatcher.intent_payload/2` broadcasts, wrapped
  # in the `event_topic` envelope the Router publishes.
  defp trigger_meta(overrides) do
    payload =
      Map.merge(
        %{
          intent_id: Platform.Types.UUIDv7.generate(),
          meeting_id: nil,
          room_id: "room-#{System.unique_integer([:positive])}",
          space_id: nil,
          transcript_id: nil,
          chunk_excerpt: "I'll revert onboarding by Friday",
          classified_intent: "action_items",
          confidence: 0.9,
          speaker: "Priya"
        },
        overrides
      )

    %{kind: :event_topic, topic: "meeting:some_intent", payload: payload}
  end

  describe "gather_context/2" do
    for handler <- @handlers do
      test "#{inspect(handler)} names the space for the dispatch invite" do
        handler = unquote(handler)
        space_id = Ecto.UUID.generate()

        {:ok, ctx} =
          handler.gather_context(responsibility(handler), trigger_meta(%{space_id: space_id}))

        # The opt-in key the Router reads. Without it
        # `Router.put_dispatch_space/2` writes no `metadata.space_id`, the
        # funnel takes the `:no_space_named` skip, and the recipient is
        # not a participant of the space this very prompt tells it to
        # write into.
        assert ctx.dispatch_space_id == space_id

        # Resolved ONCE: the inventory and the invite must name the same
        # space, or the recipient is shown one space's canvases and made
        # writable in another.
        assert ctx.meeting_canvases.space_id == space_id
      end

      test "#{inspect(handler)} falls back to the meeting's own chat space" do
        handler = unquote(handler)
        meeting = create_meeting!()

        {:ok, ctx} =
          handler.gather_context(
            responsibility(handler),
            trigger_meta(%{meeting_id: meeting.id, space_id: nil})
          )

        # The production case. `intent_payload/2` stamps `space_id` off
        # the room's TRANSCRIPT row, which mid-meeting frequently does not
        # exist yet — so the meeting's `chat_space_id` is what actually
        # resolves most of the time.
        assert ctx.dispatch_space_id == meeting.chat_space_id
        assert Chat.get_space(meeting.chat_space_id)
      end
    end
  end

  describe "the DB row (what production renders)" do
    for handler <- @handlers do
      test "#{inspect(handler)} interpolates the space id into the system turn" do
        handler = unquote(handler)
        space_id = Ecto.UUID.generate()

        {:ok, ctx} =
          handler.gather_context(responsibility(handler), trigger_meta(%{space_id: space_id}))

        assert {:ok, %{system: system}} = handler.build_prompt(ctx)

        # A value that exists ONLY in the assigns. Nothing else in the
        # system turn carries this space id — the inventory renders canvas
        # ids and the ack preamble renders the intent id — so a match here
        # cannot come from anywhere but the `meeting_space_id` assign.
        assert system =~ space_id,
               "#{inspect(handler)} rendered no space id; the recipient cannot name where to write"

        refute system =~ "{{"
      end

      test "#{inspect(handler)}'s row DECLARES meeting_space_id" do
        handler = unquote(handler)
        slug = handler.template_slug()

        assert %{content: content, variables: variables} =
                 PromptTemplates.get_template_by_slug(slug),
               "#{slug} is not seeded — the migration did not run"

        # The declared set and the interpolated set, in both directions.
        # A marker nothing declares is as much a defect as a declared
        # variable the body never uses: `prompt_template_update` shows an
        # operator the declared list, and an undeclared marker is one they
        # will not know they can feed.
        assert "meeting_space_id" in variables
        assert content =~ "{{meeting_space_id}}"

        declared = MapSet.new(variables)

        present =
          MapSet.new(
            Regex.scan(~r/\{\{(\w+)\}\}/, content, capture: :all_but_first)
            |> List.flatten()
          )

        assert declared == present,
               "#{slug}: variables #{inspect(variables)} != markers #{inspect(MapSet.to_list(present))}"
      end
    end
  end

  describe "the inline fallback (what a rollout gap renders)" do
    for handler <- @handlers do
      test "#{inspect(handler)}'s fallback body feeds every marker, space included" do
        handler = unquote(handler)
        slug = handler.template_slug()
        space_id = Ecto.UUID.generate()

        template = PromptTemplates.get_template_by_slug(slug)
        assert template, "the row must exist for its removal to prove anything"
        {:ok, _} = PromptTemplates.delete_template(template)

        {:ok, ctx} =
          handler.gather_context(responsibility(handler), trigger_meta(%{space_id: space_id}))

        {result, log} = with_log(fn -> handler.build_prompt(ctx) end)

        assert {:ok, %{system: system}} = result
        assert log =~ "#{slug} missing", "a silent fallback is how a rollout gap goes unnoticed"

        # `substitute/2` replaces only the markers it has an assign for,
        # so a `{{meeting_space_id}}` added to the fallback without a
        # matching assign survives literally. That is the drift this
        # refutes — and the positive match keeps it from passing on a body
        # that dropped the marker instead of feeding it.
        refute system =~ "{{"
        assert system =~ space_id
      end
    end
  end

  describe "absence is stated, never blank" do
    test "a payload with no space and no meeting renders a sentence, not an empty slot" do
      # A direct `Router.fire/2` from a console. `format_space/1` must not
      # interpolate to "" — a heading with nothing under it reads to a
      # model as a section that was truncated rather than one that is
      # empty, and here it would read as an unnamed space to guess at.
      assert IntentContext.format_space(%{space_id: nil}) =~ "no chat space"
      assert IntentContext.format_space(%{}) =~ "no chat space"
      assert IntentContext.format_space(%{space_id: ""}) =~ "no chat space"

      {:ok, ctx} =
        Handlers.MeetingActionItems.gather_context(
          responsibility(Handlers.MeetingActionItems),
          trigger_meta(%{})
        )

      assert ctx.dispatch_space_id == nil
      assert {:ok, %{system: system}} = Handlers.MeetingActionItems.build_prompt(ctx)
      assert system =~ "no chat space"
    end
  end
end
