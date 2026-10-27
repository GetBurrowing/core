defmodule Platform.Meetings.CandidateCorrectionTest do
  @moduledoc """
  `Candidates.correct/3` and `Candidates.rearm/2` — a correction is a
  durable corpus row and a restored countdown (task 01a0740e stage 1).

  ## Every assertion goes to the DATABASE

  The claim this stage exists to make true is that a correction WROTE
  something, so a test that reads only the return value proves nothing:
  a `correct/3` that answered `{:ok, candidate}` and inserted no row
  would satisfy it. Every case below counts
  `meeting_intent_corrections` with `Repo.aggregate/3` and reloads the
  candidate out of Postgres.

  ## The armed fixture is deliberately PART-SPENT

  `armed!/2` stamps `acts_at` five seconds out, not thirty. The re-arm
  assertions therefore cannot pass unless `correct/3` actually moved the
  deadline — against a fixture already sitting at thirty, a `correct/3`
  that never called `rearm/2` would be green. That is the exact bug this
  ticket is about: a correction that costs the corrector the review
  window makes stop-rather-than-correct the cheaper move.

  ## What "changed nothing" is asserted against

  The refusal tests compare the WHOLE reloaded struct against the whole
  struct read before the call. Any write at all moves `updated_at`, so
  struct equality is a byte-for-byte claim rather than a spot check on
  the two or three columns the correction would have touched.
  """

  use Platform.DataCase, async: true

  alias Platform.Meetings.Candidates
  alias Platform.Meetings.Countdown
  alias Platform.Meetings.IntentCorrection
  alias Platform.Meetings.MeetingCandidate
  alias Platform.Repo

  setup do
    meeting = create_meeting!(Platform.TenancyFixtures.acme_org_id())

    %{
      meeting: meeting,
      scribe: insert_agent!("scribe"),
      designer: insert_agent!("designer"),
      now: DateTime.utc_now()
    }
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp create_meeting!(org_id) do
    n = System.unique_integer([:positive])

    {:ok, project} = Platform.Tasks.create_project(%{name: "Correction #{n}", org_id: org_id})

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Correction Space #{n}",
        slug: "correction-#{n}",
        kind: "meeting"
      })

    %Platform.Meetings.Meeting{}
    |> Platform.Meetings.Meeting.changeset(%{
      project_id: project.id,
      chat_space_id: space.id,
      slug: "correction-meeting-#{n}",
      name: "Correction Meeting",
      livekit_room_name: "meeting-#{Ecto.UUID.generate()}"
    })
    |> Repo.insert!()
  end

  defp insert_agent!(prefix) do
    slug = "#{prefix}-#{System.unique_integer([:positive])}"

    %Platform.Agents.Agent{}
    |> Platform.Agents.Agent.changeset(%{
      slug: slug,
      name: slug,
      status: "active",
      kind: "native"
    })
    |> Repo.insert!()
  end

  # An OPEN card with FIVE seconds left, not thirty. See the moduledoc.
  defp armed!(%{meeting: meeting, scribe: scribe, now: now}, overrides \\ %{}) do
    {:ok, candidate} =
      Candidates.create(
        Map.merge(
          %{
            meeting_id: meeting.id,
            evidence_quote: "somebody should rotate the staging secrets",
            speaker: "alice",
            classified_intent: "action_items",
            assigned_agent_id: scribe.id,
            assigned_agent_slug: scribe.slug,
            target_role: "meeting_scribe",
            state: :shaping,
            outcome_kind: :task,
            acts_at: DateTime.add(now, 5, :second)
          },
          overrides
        )
      )

    # Existing pre-cutover armed rows still support correction controls.
    candidate
    |> Ecto.Changeset.change(acts_at: Map.get(overrides, :acts_at, DateTime.add(now, 5, :second)))
    |> Repo.update!()
  end

  defp reload!(%MeetingCandidate{id: id}), do: Repo.get!(MeetingCandidate, id)

  defp corrections, do: Repo.all(IntentCorrection)

  defp correction_count, do: Repo.aggregate(IntentCorrection, :count)

  defp only_correction! do
    assert correction_count() == 1
    [row] = corrections()
    row
  end

  # ── the three kinds each write exactly one row ────────────────────────────

  describe "correct/3 writes the corpus row" do
    test ":reassign writes one :corrected / :wrong_target row naming the new agent", ctx do
      candidate = armed!(ctx)
      actor = Ecto.UUID.generate()

      assert {:ok, _} =
               Candidates.correct(candidate, :reassign,
                 agent_id: ctx.designer.id,
                 actor_participant_id: actor,
                 actor_name: "Alice",
                 now: ctx.now
               )

      row = only_correction!()

      assert row.correction == :corrected
      assert row.reason == :wrong_target
      assert row.corrected_target_agent_id == ctx.designer.id
      assert row.classified_target_agent_id == ctx.scribe.id
      assert row.classified_intent == "action_items"
      assert row.meeting_id == ctx.meeting.id
      assert row.transcript_chunk_excerpt == candidate.evidence_quote
      assert row.actor_participant_id == actor

      # The card moved with it, slug included — the rail renders the
      # slug, so an id that moved alone would keep showing the old name.
      reloaded = reload!(candidate)
      assert reloaded.assigned_agent_id == ctx.designer.id
      assert reloaded.assigned_agent_slug == ctx.designer.slug
    end

    test ":flip_outcome to :artifact writes :corrected / :wrong_intent with brief_worthy", ctx do
      candidate = armed!(ctx)

      assert {:ok, _} = Candidates.correct(candidate, :flip_outcome, now: ctx.now)

      row = only_correction!()

      assert row.correction == :corrected
      assert row.reason == :wrong_intent
      assert row.corrected_intent == "brief_worthy"
      assert row.corrected_target_agent_id == nil

      assert reload!(candidate).outcome_kind == :artifact
    end

    test ":flip_outcome back to :task writes action_items", ctx do
      candidate = armed!(ctx, %{outcome_kind: :artifact})

      assert {:ok, _} = Candidates.correct(candidate, :flip_outcome, now: ctx.now)

      row = only_correction!()

      assert row.corrected_intent == "action_items"
      assert reload!(candidate).outcome_kind == :task
    end

    test ":not_an_action writes one :removed_no_action / :not_actionable row", ctx do
      candidate = armed!(ctx)

      assert {:ok, _} =
               Candidates.correct(candidate, :not_an_action,
                 actor_name: "Alice",
                 now: ctx.now
               )

      row = only_correction!()

      assert row.correction == :removed_no_action
      assert row.reason == :not_actionable
      assert row.corrected_intent == nil
      assert row.corrected_target_agent_id == nil
    end

    test "dispatch_outcome is left nil — an armed card never left the queue", ctx do
      candidate = armed!(ctx)

      assert {:ok, _} = Candidates.correct(candidate, :not_an_action, now: ctx.now)

      assert only_correction!().dispatch_outcome == nil
    end

    test "org_id is derived from the meeting rather than passed", ctx do
      candidate = armed!(ctx)

      assert {:ok, _} = Candidates.correct(candidate, :not_an_action, now: ctx.now)

      assert only_correction!().org_id == Platform.TenancyFixtures.acme_org_id()
    end
  end

  # ── the re-arm ────────────────────────────────────────────────────────────

  describe "correct/3 gives the countdown back" do
    test ":reassign disarms a stale task countdown", ctx do
      candidate = armed!(ctx)

      # The control. Without it the assertion below is satisfied by a
      # fixture that was already sitting at thirty.
      assert Countdown.remaining_seconds(candidate.acts_at, ctx.now) == 5

      assert {:ok, _} =
               Candidates.correct(candidate, :reassign, agent_id: ctx.designer.id, now: ctx.now)

      assert is_nil(reload!(candidate).acts_at)
    end

    test ":flip_outcome restores the FULL 30 seconds", ctx do
      candidate = armed!(ctx)
      assert Countdown.remaining_seconds(candidate.acts_at, ctx.now) == 5

      assert {:ok, _} = Candidates.correct(candidate, :flip_outcome, now: ctx.now)

      assert Countdown.remaining_seconds(reload!(candidate).acts_at, ctx.now) == 30
    end

    test ":not_an_action leaves the card closed and disarmed", ctx do
      candidate = armed!(ctx)

      assert {:ok, _} = Candidates.correct(candidate, :not_an_action, actor_name: "Alice")

      closed = reload!(candidate)
      assert closed.state == :closed
      assert closed.closed_reason == :dismissed
      assert closed.acts_at == nil
      # The note names the correction rather than a generic stop, so the
      # closed row records WHY it closed.
      assert closed.closed_note == "Corrected: not an action, by Alice"
    end

    test "a correction on a DISARMED but open card is recorded and applied, still disarmed",
         ctx do
      candidate = armed!(ctx, %{acts_at: nil})

      assert {:ok, _} =
               Candidates.correct(candidate, :reassign, agent_id: ctx.designer.id, now: ctx.now)

      assert correction_count() == 1

      reloaded = reload!(candidate)
      assert reloaded.assigned_agent_id == ctx.designer.id
      # Minting thirty fresh seconds here would invent a consent nobody
      # gave — see `reopen/2`'s doc.
      assert reloaded.acts_at == nil
    end
  end

  # ── refusals write nothing and change nothing ─────────────────────────────

  describe "correct/3 refuses before it writes" do
    test ":reassign to the agent already on the card writes NOTHING and errors", ctx do
      candidate = armed!(ctx)
      before = reload!(candidate)

      assert {:error, :same_agent} =
               Candidates.correct(candidate, :reassign, agent_id: ctx.scribe.id, now: ctx.now)

      assert correction_count() == 0
      assert reload!(candidate) == before
    end

    test ":reassign to an agent that does not exist writes NOTHING and errors", ctx do
      candidate = armed!(ctx)
      before = reload!(candidate)

      assert {:error, :unknown_agent} =
               Candidates.correct(candidate, :reassign,
                 agent_id: Ecto.UUID.generate(),
                 now: ctx.now
               )

      assert correction_count() == 0
      assert reload!(candidate) == before
    end

    test ":reassign with no agent id writes NOTHING and errors", ctx do
      candidate = armed!(ctx)
      before = reload!(candidate)

      assert {:error, :no_agent} = Candidates.correct(candidate, :reassign, now: ctx.now)

      assert correction_count() == 0
      assert reload!(candidate) == before
    end

    test ":flip_outcome on a card that already minted a task fails CLEANLY", ctx do
      # `validate_artifact_has_no_task/1`: an :artifact candidate must
      # not carry a task_id. The refusal has to land BEFORE the corpus
      # write, or the corpus carries an exemplar for a flip that never
      # happened.
      candidate = armed!(ctx, %{task_id: Ecto.UUID.generate()})
      before = reload!(candidate)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Candidates.correct(candidate, :flip_outcome, now: ctx.now)

      assert Keyword.has_key?(changeset.errors, :task_id)
      assert correction_count() == 0
      assert reload!(candidate) == before
    end

    test "an unrecognised kind writes NOTHING and errors", ctx do
      candidate = armed!(ctx)
      before = reload!(candidate)

      assert {:error, :unknown_correction} =
               Candidates.correct(candidate, :nonsense, now: ctx.now)

      assert correction_count() == 0
      assert reload!(candidate) == before
    end

    test "a missing candidate writes NOTHING", _ctx do
      assert {:error, :not_found} = Candidates.correct(Ecto.UUID.generate(), :not_an_action)

      assert correction_count() == 0
    end
  end

  # ── the nil classified_intent ─────────────────────────────────────────────

  describe "a card the classifier never answered for" do
    test ":not_an_action on a nil-intent card writes a row that PASSES the changeset", ctx do
      # A push-to-talk press released without speech opens exactly this
      # card. `classified_intent` is REQUIRED on the corpus row, so the
      # `to_string(x || "")` shape would be rejected here and leave only
      # a log line.
      candidate = armed!(ctx, %{classified_intent: nil})

      assert {:ok, _} = Candidates.correct(candidate, :not_an_action, now: ctx.now)

      row = only_correction!()
      assert row.classified_intent == Candidates.unclassified_intent()
      assert row.classified_intent == "unclassified"
      assert row.correction == :removed_no_action
    end

    test ":reassign on a nil-intent task card writes the sentinel and disarms", ctx do
      candidate = armed!(ctx, %{classified_intent: nil})

      assert {:ok, _} =
               Candidates.correct(candidate, :reassign, agent_id: ctx.designer.id, now: ctx.now)

      assert only_correction!().classified_intent == "unclassified"
      assert is_nil(reload!(candidate).acts_at)
    end

    test ":flip_outcome on a nil-intent card writes the sentinel and a corrected_intent", ctx do
      candidate = armed!(ctx, %{classified_intent: nil})

      assert {:ok, _} = Candidates.correct(candidate, :flip_outcome, now: ctx.now)

      row = only_correction!()
      assert row.classified_intent == "unclassified"
      # Without this the cross-field rule rejects the row.
      assert row.corrected_intent == "brief_worthy"
    end

    test "the sentinel is not a real routable intent", _ctx do
      # `off_topic` would have satisfied the required column too, and it
      # is exactly the wrong answer: it is a judgement the model makes,
      # and this corpus is read back into the model's own prompt.
      refute Candidates.unclassified_intent() in Platform.Meetings.IntentRouting.intents()
      refute Candidates.unclassified_intent() == "off_topic"
    end
  end

  # ── rearm/2 on its own ────────────────────────────────────────────────────

  describe "rearm/2" do
    test "it refuses stale armed task cards", ctx do
      candidate = armed!(ctx)
      assert {:error, :not_armed} = Candidates.rearm(candidate, ctx.now)
    end

    test "it restores the artifact countdown", ctx do
      candidate = armed!(ctx, %{outcome_kind: :artifact})
      assert {:ok, rearmed} = Candidates.rearm(candidate, ctx.now)
      assert rearmed.acts_at == Countdown.acts_at(ctx.now)
    end

    test "it refuses a disarmed card", ctx do
      candidate = armed!(ctx, %{acts_at: nil})
      before = reload!(candidate)

      assert {:error, :not_armed} = Candidates.rearm(candidate, ctx.now)
      assert reload!(candidate) == before
    end

    test "it refuses a closed card", ctx do
      candidate = armed!(ctx)
      {:ok, _} = Candidates.stop(candidate, Ecto.UUID.generate())
      before = reload!(candidate)

      assert before.state == :closed

      assert {:error, :not_armed} = Candidates.rearm(candidate, ctx.now)
      assert reload!(candidate) == before
    end

    test "it refuses a candidate that does not exist", ctx do
      assert {:error, :not_found} = Candidates.rearm(Ecto.UUID.generate(), ctx.now)
    end
  end

  # ── A REFUSAL RAISED INSIDE THE TRANSACTION (task 01a0913b) ───────────
  #
  # Stage 1 of task 01a0740e made the order a REQUIREMENT: the corpus row
  # is written before the candidate is touched, so that "the card moved
  # and the classifier learned nothing" has no ordering in which it can
  # happen. Its stage 3 then MEASURED the price of that order: every
  # refusal raised by `stop/3` rather than by `plan_correction/3` left
  # the exemplar behind, because the insert had already committed.
  #
  # That gap is CLOSED (task 01a0913b). `correct/3` now runs the corpus
  # write and the apply in one `Repo.transaction/1` and rolls back on any
  # `{:error, _}`, so the row commits if and only if the card's change
  # does. The write still comes first — inside the transaction — so the
  # original requirement stands; what changed is that a refusal after it
  # takes the row with it.
  #
  # Both refusals are reachable without racing anything. `:not_an_action`
  # is the only kind that closes through `stop/3`, and `stop/3` has
  # exactly two ways to say `:already_fired`: a card that graduated
  # (`disposition == :accepted`) and a card the sweeper has already
  # claimed (`:acting` AND disarmed, the pair `do_stop/3` matches on). A
  # participant reaches either the same way — their browser is showing
  # the card as armed because it painted a second ago.
  #
  # The quantity every case below discriminates on is the corpus COUNT,
  # read before and after the call. A return value is not evidence: the
  # pre-fix code returned exactly the same `{:error, :already_fired}`
  # while leaving the row behind.

  describe "a refusal raised by stop/3 inside the transaction" do
    test ":not_an_action on a card that ALREADY GRADUATED errors and writes NOTHING", ctx do
      # `stop/3` reads `disposition == :accepted` as "this already went
      # ahead", which is a different fact from "somebody already stopped
      # it" and the only one that means a task now exists.
      candidate =
        armed!(ctx, %{
          state: :closed,
          closed_reason: :done,
          disposition: :accepted,
          acts_at: nil
        })

      before = reload!(candidate)

      # The premise, read back from Postgres rather than assumed from the
      # fixture's attrs: if `create/1` ever dropped one of these, this
      # test would be exercising a different branch of `stop/3`.
      assert before.disposition == :accepted
      assert before.state == :closed

      count_before = correction_count()
      assert count_before == 0

      assert {:error, :already_fired} =
               Candidates.correct(candidate, :not_an_action, actor_name: "Alice", now: ctx.now)

      assert correction_count() == count_before
      assert correction_count() == 0
      assert reload!(candidate) == before
    end

    test ":not_an_action on a card the SWEEPER has claimed errors and writes NOTHING", ctx do
      # `:acting` AND disarmed is the pair `do_stop/3`'s where clause
      # excludes — the sweeper's claim. `:acting` alone is not it: the
      # ack mirror writes that state on a card still counting down, and
      # such a card must stay stoppable.
      candidate = armed!(ctx, %{state: :acting, acts_at: nil})

      before = reload!(candidate)
      assert before.state == :acting
      assert before.acts_at == nil

      count_before = correction_count()

      assert {:error, :already_fired} =
               Candidates.correct(candidate, :not_an_action, actor_name: "Alice", now: ctx.now)

      assert correction_count() == count_before
      assert correction_count() == 0
      assert reload!(candidate) == before
    end

    test ":not_an_action on a live, armed :shaping card writes exactly ONE row and closes it",
         ctx do
      # THE POSITIVE CONTROL for the two refusals above. Without it, a
      # `correct/3` that rolled back EVERY `:not_an_action` would pass
      # them. Green before and after task 01a0913b — it is a guard on the
      # success path, not a red test.
      candidate = armed!(ctx)

      before = reload!(candidate)
      refute before.state == :closed
      refute is_nil(before.acts_at)

      count_before = correction_count()

      assert {:ok, _} =
               Candidates.correct(candidate, :not_an_action, actor_name: "Alice", now: ctx.now)

      assert correction_count() == count_before + 1

      closed = reload!(candidate)
      assert closed.state == :closed
      assert closed.closed_reason == :dismissed
      assert closed.acts_at == nil
      assert String.starts_with?(closed.closed_note, "Corrected: not an action")
    end

    test "an :acting card that is still ARMED is corrected normally", ctx do
      # THE POSITIVE CONTROL for the sweeper case, and the reason it
      # spells the claim as a PAIR. If `:acting` alone were treated as
      # claimed, every dispatched card would become uncorrectable while
      # its countdown was still visibly running.
      candidate = armed!(ctx, %{state: :acting})

      count_before = correction_count()

      assert {:ok, _} =
               Candidates.correct(candidate, :not_an_action, actor_name: "Alice", now: ctx.now)

      assert correction_count() == count_before + 1

      closed = reload!(candidate)
      assert closed.state == :closed
      assert closed.closed_reason == :dismissed
    end
  end

  # ── candidate events around the transaction (task 01a0913b) ──────────
  #
  # `emit/3` INSERTS a `meeting_candidate_events` row and immediately
  # broadcasts it. Inside `correct/3`'s transaction those are queued and
  # flushed after commit, so another MeetingLive re-reading the board on
  # its own connection cannot see the card still open. The first two
  # cases are GUARDS that pass before and after task 01a0913b: they pin
  # that deferral neither drops nor reorders events on success, and that
  # a refusal broadcasts nothing. Neither can observe "broadcast before
  # commit" — the ExUnit sandbox runs everything on one connection. The
  # third case is the one that orders the writes, and it does so through
  # Ecto's query telemetry rather than through a second reader.

  describe "candidate events and the correction transaction" do
    test "a successful :not_an_action still broadcasts and records :closed then :countdown_stopped",
         ctx do
      # GUARD: green before and after task 01a0913b.
      candidate = armed!(ctx)
      :ok = Platform.Meetings.PubSub.subscribe_candidate_events(ctx.meeting.id)

      assert {:ok, _} =
               Candidates.correct(candidate, :not_an_action, actor_name: "Alice", now: ctx.now)

      assert_receive {:candidate_event, %{kind: first, candidate_id: id1}}, 1_000
      assert_receive {:candidate_event, %{kind: second, candidate_id: id2}}, 1_000
      assert {first, second} == {:closed, :countdown_stopped}
      assert id1 == candidate.id and id2 == candidate.id

      kinds = event_kinds(candidate)
      assert :closed in kinds
      assert :countdown_stopped in kinds
    end

    test "a refused :not_an_action broadcasts nothing and records no event", ctx do
      # GUARD: green before and after task 01a0913b — `stop/3`'s
      # `:already_fired` branches return before any `emit/3`.
      candidate =
        armed!(ctx, %{
          state: :closed,
          closed_reason: :done,
          disposition: :accepted,
          acts_at: nil
        })

      events_before = event_count(candidate)
      :ok = Platform.Meetings.PubSub.subscribe_candidate_events(ctx.meeting.id)

      assert {:error, :already_fired} =
               Candidates.correct(candidate, :not_an_action, actor_name: "Alice", now: ctx.now)

      refute_receive {:candidate_event, _}, 200
      assert event_count(candidate) == events_before
    end

    test "the event rows are written AFTER the transaction that wrote the corpus row commits",
         ctx do
      # The ordering the deferral exists for, read off the statements
      # this process sent. Before task 01a0913b there was no transaction
      # at all, so this fails on the missing "begin"; with a transaction
      # but WITHOUT the deferral, the event inserts land between "begin"
      # and "commit" and it fails on the order.
      candidate = armed!(ctx)

      queries =
        capture_own_queries(fn ->
          assert {:ok, _} =
                   Candidates.correct(candidate, :not_an_action,
                     actor_name: "Alice",
                     now: ctx.now
                   )
        end)

      begin_at = Enum.find_index(queries, &(&1 == "begin"))
      commit_at = Enum.find_index(queries, &(&1 == "commit"))

      correction_at =
        Enum.find_index(
          queries,
          &String.contains?(&1, "INSERT INTO \"meeting_intent_corrections\"")
        )

      event_inserts =
        queries
        |> Enum.with_index()
        |> Enum.filter(fn {q, _} ->
          String.contains?(q, "INSERT INTO \"meeting_candidate_events\"")
        end)
        |> Enum.map(fn {_, i} -> i end)

      assert is_integer(begin_at), "no transaction began: #{inspect(queries)}"
      assert is_integer(commit_at), "no transaction committed: #{inspect(queries)}"
      assert is_integer(correction_at)
      assert begin_at < correction_at and correction_at < commit_at
      assert length(event_inserts) == 2
      assert Enum.all?(event_inserts, &(&1 > commit_at)), inspect(queries)
    end
  end

  defp event_kinds(%MeetingCandidate{id: id}) do
    import Ecto.Query

    Platform.Meetings.MeetingCandidateEvent
    |> where([e], e.candidate_id == ^id)
    |> select([e], e.kind)
    |> Repo.all()
  end

  defp event_count(candidate), do: length(event_kinds(candidate))

  # Every statement THIS process sent while `fun` ran. Telemetry handlers
  # run in the emitting process and are global, so the `self()` check is
  # what keeps sibling `async: true` files out of the list.
  defp capture_own_queries(fun) do
    test_pid = self()
    handler_id = "correction-queries-#{System.unique_integer([:positive])}"
    event = Platform.Repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, meta, _config ->
          if self() == test_pid do
            send(test_pid, {:own_query, handler_id, Map.get(meta, :query)})
          end
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    collect_own_queries(handler_id, [])
  end

  defp collect_own_queries(handler_id, acc) do
    receive do
      {:own_query, ^handler_id, query} -> collect_own_queries(handler_id, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
