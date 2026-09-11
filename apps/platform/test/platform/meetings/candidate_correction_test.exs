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
    meeting = create_meeting!(Platform.TenancyFixtures.fabrikam_org_id())

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

    candidate
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

      assert only_correction!().org_id == Platform.TenancyFixtures.fabrikam_org_id()
    end
  end

  # ── the re-arm ────────────────────────────────────────────────────────────

  describe "correct/3 gives the countdown back" do
    test ":reassign restores the FULL 30 seconds, not the 5 that were left", ctx do
      candidate = armed!(ctx)

      # The control. Without it the assertion below is satisfied by a
      # fixture that was already sitting at thirty.
      assert Countdown.remaining_seconds(candidate.acts_at, ctx.now) == 5

      assert {:ok, _} =
               Candidates.correct(candidate, :reassign, agent_id: ctx.designer.id, now: ctx.now)

      assert Countdown.remaining_seconds(reload!(candidate).acts_at, ctx.now) == 30
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

    test ":reassign on a nil-intent card writes the sentinel and re-arms", ctx do
      candidate = armed!(ctx, %{classified_intent: nil})

      assert {:ok, _} =
               Candidates.correct(candidate, :reassign, agent_id: ctx.designer.id, now: ctx.now)

      assert only_correction!().classified_intent == "unclassified"
      assert Countdown.remaining_seconds(reload!(candidate).acts_at, ctx.now) == 30
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
    test "it sets the full countdown from now", ctx do
      candidate = armed!(ctx)

      assert {:ok, rearmed} = Candidates.rearm(candidate, ctx.now)

      assert rearmed.acts_at == Countdown.acts_at(ctx.now)
      assert Countdown.remaining_seconds(reload!(candidate).acts_at, ctx.now) == 30
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

  # ── WHAT THE WRITE-FIRST ORDER COSTS (task 01a0740e stage 3) ──────────
  #
  # Stage 1's plan made the order a REQUIREMENT: the corpus row is
  # written before the candidate is touched, so that "the card moved and
  # the classifier learned nothing" has no ordering in which it can
  # happen. The two cases below are the price of that choice, measured
  # rather than assumed, because `correct/3`'s own doc used to claim the
  # converse as well — that no refusal can leave an exemplar behind —
  # and that claim is FALSE for every refusal raised by `stop/3` rather
  # than by `plan_correction/3`.
  #
  # Both are reachable without racing anything. `:not_an_action` is the
  # only kind that closes through `stop/3`, and `stop/3` has exactly two
  # ways to say `:already_fired`: a card that graduated
  # (`disposition == :accepted`) and a card the sweeper has already
  # claimed (`:acting` AND disarmed, the pair `do_stop/3` matches on).
  # A participant reaches either of them the same way — their browser is
  # showing the card as armed because it painted a second ago.
  #
  # These tests PIN today's behaviour; they do not bless it. The row
  # that survives says `correction: :removed_no_action` with a nil
  # `dispatch_outcome`, which `IntentCorrection`'s moduledoc defines as
  # "it never left the queue" — and for a graduated card that is not
  # true. `IntentCorrections.recent_exemplars/2` feeds these rows to the
  # classifier as few-shot examples, so it is a wrong example rather
  # than merely a spare one. Whether that is worth closing (it needs a
  # transaction around the write and the apply; a precheck cannot, since
  # the sweeper can claim the row between the check and the write) is a
  # corpus-quality decision this stage does not get to take on its own.
  # If it is ever taken, these two tests are what should change, and
  # they should change to `correction_count() == 0`.

  describe "a refusal raised AFTER the corpus write" do
    test ":not_an_action on a card that ALREADY GRADUATED errors and the exemplar STAYS", ctx do
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

      assert {:error, :already_fired} =
               Candidates.correct(candidate, :not_an_action, actor_name: "Alice", now: ctx.now)

      # The card is untouched, which is the invariant that DOES hold.
      assert reload!(candidate) == before

      # And the exemplar is already in the corpus, which is the one that
      # does not. See the note above this describe block.
      assert correction_count() == 1
      assert only_correction!().correction == :removed_no_action
      assert only_correction!().dispatch_outcome == nil
    end

    test ":not_an_action on a card the SWEEPER has claimed errors and the exemplar STAYS", ctx do
      # `:acting` AND disarmed is the pair `do_stop/3`'s where clause
      # excludes — the sweeper's claim. `:acting` alone is not it: the
      # ack mirror writes that state on a card still counting down, and
      # such a card must stay stoppable.
      candidate = armed!(ctx, %{state: :acting, acts_at: nil})

      before = reload!(candidate)

      assert {:error, :already_fired} =
               Candidates.correct(candidate, :not_an_action, actor_name: "Alice", now: ctx.now)

      assert reload!(candidate) == before
      assert correction_count() == 1
    end

    test "an :acting card that is still ARMED is corrected normally", ctx do
      # THE POSITIVE CONTROL for the case above, and the reason it spells
      # the claim as a PAIR. If `:acting` alone were treated as claimed,
      # every dispatched card would become uncorrectable while its
      # countdown was still visibly running.
      candidate = armed!(ctx, %{state: :acting})

      assert {:ok, _} =
               Candidates.correct(candidate, :not_an_action, actor_name: "Alice", now: ctx.now)

      assert correction_count() == 1

      closed = reload!(candidate)
      assert closed.state == :closed
      assert closed.closed_reason == :dismissed
    end
  end
end
