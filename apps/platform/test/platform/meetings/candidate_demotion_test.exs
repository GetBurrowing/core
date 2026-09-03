defmodule Platform.Meetings.CandidateDemotionTest do
  @moduledoc """
  `demoted_from` — the column that makes an `off_topic` candidate
  readable (task 01a06575 stage 1).

  ## The ambiguity under test

  `IntentClassifier`'s evidence gate DEMOTES a positive classification
  to `off_topic` when the model's `evidence_quote` is blank, is not a
  verbatim span of the chunk, or sits in a cancelling frame. The
  demotion preserves the model's ORIGINAL confidence. So before this
  stage a demoted row and a genuine decline were byte-identical in
  Postgres — same `classified_intent`, same `target_role`, same
  `classifier_confidence` — and 268 production rows could not be sorted
  into the two populations by any query.

  ## Why every assertion reads the row back out of Postgres

  The field crosses two silent filters on its way to the column:

    * `IntentQueue.Server`'s `@writable_fields`, applied as
      `Map.take/2`, and
    * `MeetingCandidate`'s `@cast_fields`, applied as `cast/3`.

  Both DROP an unknown key without an error, a warning or a changeset
  failure. A test that asserted on the map handed to
  `Candidates.create_or_attach/1` — or on the struct a write returned in
  memory — therefore passes green against an implementation in which the
  column is never written at all and reads back nil forever. Every
  assertion below goes through `Repo` after the write, and the mutation
  that proves it (removing `:demoted_from` from `@writable_fields`) is
  recorded in the stage report.

  ## Why (b) and (c) are asserted against each other, not just apart

  Two tests that each pass alone would also be satisfied by an
  implementation that wrote `demoted_from` from `classified_intent` — or
  by one that never wrote it and left both nil. `separable in one
  query` below puts a demoted row and a genuine decline in the SAME
  meeting, asserts they agree on every other classified column, and
  partitions them on this one.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Meetings.IntentClassifier
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Roles

  @responsibility_key "meetings.intent_classify"

  # Both clear `content_bearing?/1` — asserted below with a positive
  # control, because a chunk the gate drops never reaches the model and
  # every scenario built on it would be vacuously green.
  @dashboard "we should make the dashboard load faster"
  @offsite "can someone book the offsite room"
  @filler "yeah"

  # NOT a span of @dashboard. This is the whole of case (b): an honest
  # model that restates rather than quotes.
  @paraphrase "the dashboard ought to be quicker to load"

  defmodule StubProvider do
    @moduledoc false
    def chat(credentials, messages, opts) do
      case Process.get(:intent_classifier_stub_fun) do
        nil -> {:error, :no_stub_configured}
        fun when is_function(fun, 3) -> fun.(credentials, messages, opts)
      end
    end
  end

  setup do
    agent = create_agent!("intent-agent-demotion")
    {:ok, _} = Roles.set_override(@responsibility_key, agent.id)

    target = create_agent!("intent-target-demotion")
    :ok = Roles.unassign_role("designer")
    {:ok, _} = Roles.assign_role("designer", target.id)

    meeting_id = Ecto.UUID.generate()
    room_id = Ecto.UUID.generate()
    on_exit(fn -> IntentQueue.stop(meeting_id) end)

    %{meeting_id: meeting_id, room_id: room_id, agent: agent, target: target}
  end

  defp create_agent!(prefix) do
    %Agent{}
    |> Agent.changeset(%{
      slug: "#{prefix}-#{System.unique_integer([:positive])}",
      name: "Intent Agent",
      status: "active"
    })
    |> Repo.insert!()
  end

  defp start_classifier!(opts \\ []) do
    name = :"candidate_demotion_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      start_supervised(
        {IntentClassifier,
         opts
         |> Keyword.put_new(:provider_module, StubProvider)
         |> Keyword.put_new(:debounce_ms, 150)
         |> Keyword.put(:name, name)}
      )

    pid
  end

  defp plant_stub_fun(pid, fun) do
    ref = make_ref()
    send(pid, {:__test_plant_stub, self(), ref, fun})

    receive do
      {^ref, :ok} -> :ok
    after
      500 -> flunk("classifier did not ack stub fun plant")
    end
  end

  defp answer(overrides) do
    {:ok,
     %{
       content:
         %{
           "intent" => "visual_adjust",
           "target_role" => "designer",
           "confidence" => 0.95
         }
         |> Map.merge(overrides)
         |> Jason.encode!()
     }}
  end

  defp say(context, speaker, text) do
    chunk_id = Ecto.UUID.generate()

    :ok =
      MeetingsPubSub.broadcast_transcript_chunk(context.room_id, %{
        room_id: context.room_id,
        meeting_id: context.meeting_id,
        transcript_id: Ecto.UUID.generate(),
        segment: %{id: chunk_id, text: text, speaker_name: speaker}
      })

    chunk_id
  end

  defp say!(context, speaker, text) do
    chunk_id = say(context, speaker, text)
    assert_receive {:intent_classified, row}, 3_000
    {chunk_id, row}
  end

  # THE read-back. Not the struct a write returned, not the attrs map —
  # a fresh SELECT keyed by the transcript chunk that produced the row.
  # If `demoted_from` never reached the column, this is where it shows
  # up as nil.
  defp reload!(meeting_id, chunk_id) do
    MeetingCandidate
    |> where([c], c.meeting_id == ^meeting_id and c.transcript_chunk_id == ^chunk_id)
    |> Repo.one!()
  end

  # ── the scenario's own premises ───────────────────────────────────────────

  test "both utterances reach the classifier, and the gate can say no" do
    for text <- [@dashboard, @offsite] do
      assert IntentClassifier.content_bearing?(text),
             "#{inspect(text)} never reaches the classifier, so the scenario is vacuous"
    end

    refute IntentClassifier.content_bearing?(@filler)
  end

  test "the paraphrase really is not a span of the chunk it paraphrases" do
    # If this were a substring the evidence gate would pass it, case (b)
    # would never demote, and the test below would be asserting nil ==
    # nil for the wrong reason.
    refute String.contains?(@dashboard, @paraphrase)
    assert String.contains?(@dashboard, "make the dashboard load faster")
  end

  # ── (a) verbatim citation: the intent survives, nothing is demoted ───────

  test "a verbatim evidence_quote survives and records no demotion", context do
    pid = start_classifier!()
    plant_stub_fun(pid, fn _c, _m, _o -> answer(%{"evidence_quote" => @dashboard}) end)

    :ok = MeetingsPubSub.subscribe_intents(context.meeting_id)
    {chunk_id, queue_row} = say!(context, "alice", @dashboard)

    # The queue agrees the classification survived — so a nil
    # `demoted_from` below cannot be explained by the row having been
    # demoted and the column simply not written.
    assert queue_row.classified_intent == "visual_adjust"

    row = reload!(context.meeting_id, chunk_id)
    assert row.classified_intent == "visual_adjust"
    assert row.classifier_confidence == 0.95
    assert row.target_role == "designer"
    assert row.demoted_from == nil
  end

  # ── (b) paraphrased citation: demoted, and the row says so ───────────────

  test "a paraphrased evidence_quote demotes and records the original intent",
       context do
    pid = start_classifier!()
    plant_stub_fun(pid, fn _c, _m, _o -> answer(%{"evidence_quote" => @paraphrase}) end)

    :ok = MeetingsPubSub.subscribe_intents(context.meeting_id)
    {chunk_id, _queue_row} = say!(context, "alice", @dashboard)

    row = reload!(context.meeting_id, chunk_id)

    assert row.classified_intent == "off_topic",
           "the evidence gate must demote an uncited positive"

    assert row.demoted_from == "visual_adjust",
           "the demoted row must name the intent that was downgraded — " <>
             "nil here means the field was dropped by @writable_fields or @cast_fields"

    # The demotion PRESERVES the model's confidence. Asserted because it
    # is exactly why the two populations are otherwise indistinguishable.
    assert row.classifier_confidence == 0.95
  end

  # ── (c) a genuine decline: off_topic with nothing behind it ──────────────

  test "a model that genuinely declines records no demotion", context do
    pid = start_classifier!()

    plant_stub_fun(pid, fn _c, _m, _o ->
      answer(%{
        "intent" => "off_topic",
        "target_role" => nil,
        "evidence_quote" => ""
      })
    end)

    :ok = MeetingsPubSub.subscribe_intents(context.meeting_id)
    {chunk_id, _queue_row} = say!(context, "bruno", @offsite)

    row = reload!(context.meeting_id, chunk_id)
    assert row.classified_intent == "off_topic"
    assert row.classifier_confidence == 0.95

    assert row.demoted_from == nil,
           "a decline the model made itself must not be marked as demoted"
  end

  # ── (b) vs (c): the entire point of the stage ────────────────────────────

  test "a demoted row and a genuine decline are separable in one query", context do
    pid = start_classifier!()

    # ONE stub, branching on the chunk it is shown, so both rows are
    # produced by the same code path in the same meeting.
    plant_stub_fun(pid, fn _c, messages, _o ->
      shown =
        Enum.find_value(messages, "", fn message ->
          role = Map.get(message, :role) || Map.get(message, "role")
          if role == "user", do: Map.get(message, :content) || Map.get(message, "content")
        end)

      if String.contains?(shown, "dashboard") do
        answer(%{"evidence_quote" => @paraphrase})
      else
        answer(%{"intent" => "off_topic", "target_role" => nil, "evidence_quote" => ""})
      end
    end)

    :ok = MeetingsPubSub.subscribe_intents(context.meeting_id)

    # Different speakers, so `ThreadResolver` can never fold these into
    # one card and leave the test asserting about a single row.
    {demoted_chunk, _} = say!(context, "alice", @dashboard)
    {declined_chunk, _} = say!(context, "bruno", @offsite)

    demoted = reload!(context.meeting_id, demoted_chunk)
    declined = reload!(context.meeting_id, declined_chunk)

    refute demoted.id == declined.id

    # They agree on EVERYTHING the pre-column schema could see. This is
    # the ambiguity, demonstrated rather than asserted.
    assert demoted.classified_intent == declined.classified_intent
    assert demoted.classified_intent == "off_topic"
    assert demoted.classifier_confidence == declined.classifier_confidence
    assert demoted.target_role == declined.target_role

    # And they are told apart by the new column alone — through SQL,
    # which is the form the 268-row production question takes.
    demoted_ids =
      MeetingCandidate
      |> where([c], c.meeting_id == ^context.meeting_id)
      |> where([c], not is_nil(c.demoted_from))
      |> select([c], c.id)
      |> Repo.all()

    assert demoted_ids == [demoted.id]
  end
end
