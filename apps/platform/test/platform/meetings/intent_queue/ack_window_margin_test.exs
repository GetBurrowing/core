defmodule Platform.Meetings.IntentQueue.AckWindowMarginTest do
  @moduledoc """
  Measurement for task 019ff292 stage 1: where does the 90s ack window
  actually go?

  ## The quantity under test

  Not the timeout count. Timeout counts pass as soon as latency drops a
  little under the threshold and regress silently. The load-bearing
  number is the **margin the responder actually experiences**:

      margin = deadline - delivery

  where `delivery` is when the dispatch reaches the responder and
  `deadline` is the instant the ack path starts refusing. A responder
  cannot be held to time it never had, so the margin should be close to
  the full window no matter how long delivery took.

  ## Every timestamp here is observed, not computed

  * **creation** — decoded from the row id, which is a UUIDv7 whose
    first 48 bits are big-endian epoch-milliseconds. No column is added
    to get it.
  * **dispatch** — the arrival of the `:intent_dispatched` broadcast.
    `Server.apply_transition/4` arms the ack timer inside
    `apply_cursor_effects/3` and only then broadcasts, so this is the
    instant the deadline was set.
  * **delivery** — the arrival of the dispatch at the responder,
    modelled as `dispatch + transport_ms`. See below for why this is
    the honest model.
  * **deadline** — the arrival of the `:intent_timed_out` broadcast.
    Directly observed, which is why the margin runs deliberately do NOT
    ack: an ack would either re-arm the window (`:working` lands on
    `:acked`, which is in-flight, so `apply_cursor_effects/3` re-arms)
    or release the cursor, and in both cases the deadline stops being
    observable.

  ## Why modelling transport as a delay is not a rigged experiment

  `IntentDispatcher.send_dispatch/7` marks the row `:dispatched` —
  arming the window — and only then calls
  `IntentRuntimeAdapter.send_attention/3`, which bottoms out in
  `Federation.dispatch_intent_attention/2`: a PubSub broadcast that
  returns `:ok` unconditionally. There is no delivery receipt and no
  processing receipt anywhere on that path, so the queue never learns
  when — or whether — the dispatch arrived. Every millisecond between
  the broadcast and the responder being able to act is therefore
  charged to the responder, and nothing in the system bounds it.

  In production that gap is the federation hop, the runtime's websocket,
  the runtime's inbox, and above all the agent being mid-turn on
  unrelated work when the signal lands. None of that is reproducible in
  a unit test, and none of it needs to be: the defect is that the
  deadline is a pure function of the transmission instant, so the margin
  is `window - transport` for whatever `transport` turns out to be. That
  is the property these tests measure.

  ## What stage 2 changed here, and why the harness had to grow a call

  Stage 2's fix is `IntentQueue.mark_delivered/2`: the receipt that did
  not exist when the paragraphs above were written. The transport model
  is unchanged — delivery is still `dispatch + transport_ms`, still a
  delay the queue does not control — but at that instant the responder
  now SAYS so, exactly as a runtime does on the wire with
  `"intent_delivered"`. A measurement of an anchor that reads a signal
  cannot withhold the signal and still be measuring the anchor.

  Nothing about the timing was relaxed to accommodate it: the delivery
  call is made at the same `t_delivery` the old harness merely recorded,
  and every margin assertion below is the one stage 1 wrote.

  One stage-1 assertion HAD to change, and it is called out at its site:
  `dispatch->deadline == window`. That is a statement OF the defect —
  it says the deadline ignores transport — and it is arithmetically
  incompatible with the margin assertion sitting three lines below it.
  See the comment on `deadline is anchored at delivery` for the proof.

  Note also what this rules out. All of the dispatcher's own work —
  role resolution, agent lookup, runtime resolution, and any retry or
  backoff among them — happens BEFORE `transition(:dispatched)`. It
  lands in creation->dispatch and cannot shorten the margin. The
  dispatcher is deliberately not started here (and `config/test.exs`
  disables it anyway); driving `claim_next/1` and `transition/4`
  directly is the same queue path with one fewer variable.
  """

  # `Platform.DataCase`, not `ExUnit.Case`, since task 01a04a36 armed
  # `:intent_queue_mirror_fatal`. Nothing here reads Postgres directly;
  # what it needs is a sandbox connection the QUEUE OWNER can reach, so
  # that the candidate mirror hanging off every `enqueue`/`transition`/
  # `ack` below actually writes instead of dying on `cannot find
  # ownership process`. `IntentQueue.Supervisor.ensure_started/2`
  # propagates this process's `$callers` into the owner, so the setup
  # below needs no explicit `Sandbox.allow/3`.
  #
  # The accepted cost, recorded rather than discovered: seven cases that
  # were database-free now check out a connection each. `async: true`
  # survives — `Sandbox.start_owner!(Repo, shared: false)` gives each
  # case its own — which is the property that mattered, since these are
  # timing cases and serialising them would inflate the whole suite by
  # their real durations rather than overlapping them.
  use Platform.DataCase, async: true

  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.IntentQueue.Server
  alias Platform.Meetings.PubSub, as: MeetingsPubSub

  # Short enough to keep the suite fast, long enough that scheduler
  # jitter is noise against it.
  @window_ms 400

  # The margin a responder should get is the full window. Allow a small
  # slack for timer and scheduler jitter on a loaded box — this is
  # tolerance for measurement noise, NOT for latency.
  @jitter_ms 80

  @burst_size 5

  setup do
    # A real UUID, not `"meeting-margin-N"`. `IntentQueue.Server`
    # mirrors every queue write into `meeting_candidates`, whose
    # `meeting_id` is a `:binary_id`: a non-UUID raises
    # `Ecto.ChangeError` at dump time and the non-fatal `mirror/1`
    # wrapper swallows it into a log line, so all seven cases here ran
    # green over 14 raised-and-discarded inserts (task 01a04a36).
    #
    # Since 01a04a36 the mirror also REACHES Postgres from here: the
    # module is `DataCase` and the owner inherits this process's
    # connection, so a mirror that could not write would raise rather
    # than log. The durable mapping itself is still asserted in
    # `server_persistence_test.exs`; what these cases contribute is that
    # a real timing burst drives real inserts.
    meeting_id = Ecto.UUID.generate()
    {:ok, _} = IntentQueue.ensure_started(meeting_id, ack_timeout_ms: @window_ms)
    on_exit(fn -> IntentQueue.stop(meeting_id) end)

    :ok = MeetingsPubSub.subscribe_intents(meeting_id)

    %{meeting_id: meeting_id}
  end

  # ── Measurement harness ────────────────────────────────────────────────────

  defp enqueue!(meeting_id) do
    {:ok, row} =
      IntentQueue.enqueue(meeting_id, %{
        classified_intent: "open_question",
        target_role: "engineering",
        confidence: 0.95,
        transcript_chunk_id: Ecto.UUID.generate(),
        chunk_excerpt: "who is handling the billing bug?",
        dedupe_key: "dk-#{System.unique_integer([:positive])}"
      })

    row
  end

  defp mono_ms, do: System.monotonic_time(:millisecond)

  # UUIDv7: the first 48 bits are big-endian epoch-milliseconds.
  defp created_at_ms(id) when is_binary(id) do
    id
    |> String.replace("-", "")
    |> binary_part(0, 12)
    |> String.to_integer(16)
  end

  defp measure_margin(meeting_id, transport_ms) do
    dispatch_and_measure(meeting_id, enqueue!(meeting_id), transport_ms)
  end

  # Take one ALREADY-ENQUEUED row through claim -> dispatch -> expiry and
  # measure creation, dispatch, delivery and deadline for it.
  #
  # The row is a parameter rather than enqueued here on purpose. A burst
  # has to be enqueued up front so the queue genuinely reaches depth N
  # and rows 2..N genuinely sit behind their predecessors; enqueueing one
  # row at a time would keep the depth at 1 and silently test something
  # else — the cascade would have no chance to appear.
  #
  # Deliberately does not ack: the deadline is only directly observable
  # on a row that is left to expire, because `:working` re-arms the
  # window and a terminal ack releases the cursor.
  defp dispatch_and_measure(meeting_id, row, transport_ms) do
    # The queue hands out the oldest `:queued` row. Asserting it is the
    # one we expected keeps the burst honest: it proves the rows really
    # did drain FIFO through the serial cursor rather than in whatever
    # order made the numbers agreeable.
    {:ok, claimed} = IntentQueue.claim_next(meeting_id)
    assert claimed.id == row.id

    {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)

    intent_id = row.id
    assert_receive {:intent_dispatched, %{id: ^intent_id}}, @window_ms + 2_000
    t_dispatch = mono_ms()
    wall_dispatch = System.system_time(:millisecond)

    # The transport hop the responder does not control. Stage 1 noted
    # that the queue never observes it; stage 2's whole fix is that it
    # now can, so the responder reports first contact at exactly the
    # instant the model says the dispatch reached it. This is the
    # in-VM equivalent of a runtime sending `"intent_delivered"` on
    # `runtime:<runtime_id>` when it surfaces the intent to its agent.
    Process.send_after(self(), {:delivered, intent_id}, transport_ms)
    assert_receive {:delivered, ^intent_id}, transport_ms + 2_000
    t_delivery = mono_ms()
    {:ok, _} = IntentQueue.mark_delivered(meeting_id, intent_id)

    assert_receive {:intent_timed_out, %{id: ^intent_id}}, @window_ms + transport_ms + 3_000
    t_deadline = mono_ms()

    %{
      intent_id: intent_id,
      transport_ms: transport_ms,
      created_at_ms: created_at_ms(intent_id),
      creation_to_dispatch_ms: wall_dispatch - created_at_ms(intent_id),
      dispatch_to_deadline_ms: t_deadline - t_dispatch,
      delivery_ms: t_delivery - t_dispatch,
      margin_ms: t_deadline - t_delivery
    }
  end

  defp report(title, rows) do
    IO.puts("\n  #{title}")

    IO.puts(
      "  pos  transport_ms  created(epoch ms)  creation->dispatch  " <>
        "dispatch->deadline  margin(deadline-delivery)"
    )

    rows
    |> Enum.with_index(1)
    |> Enum.each(fn {m, i} ->
      IO.puts(
        "  #{String.pad_leading(to_string(i), 3)}  " <>
          "#{String.pad_leading(to_string(m.transport_ms), 12)}  " <>
          "#{String.pad_leading(to_string(m.created_at_ms), 17)}  " <>
          "#{String.pad_leading(to_string(m.creation_to_dispatch_ms), 18)}  " <>
          "#{String.pad_leading(to_string(m.dispatch_to_deadline_ms), 18)}  " <>
          "#{String.pad_leading(to_string(m.margin_ms), 25)}"
      )
    end)

    IO.puts("  window_ms=#{@window_ms}\n")
  end

  # ── The anchor ─────────────────────────────────────────────────────────────

  describe "where the window goes" do
    test "the deadline is anchored at delivery, so transport does not come out of the responder's window",
         %{meeting_id: meeting_id} do
      # Three transport costs, all well under the window. If the
      # deadline were anchored at delivery, all three would leave the
      # responder the same full window.
      measurements =
        for transport_ms <- [0, div(@window_ms, 4), div(@window_ms, 2)] do
          measure_margin(meeting_id, transport_ms)
        end

      report("margin vs transport latency", measurements)

      # ── The one stage-1 assertion stage 2 changed ────────────────────
      #
      # Stage 1 wrote this as `assert_in_delta dispatch_to_deadline,
      # @window_ms, @jitter_ms` — "dispatch->deadline is one window,
      # invariant to transport" — and called it the diagnosis rather
      # than the defect. It is the defect, stated as an assertion, and
      # it cannot coexist with the margin assertion below:
      #
      #   old:    deadline <= dispatch + window + jitter   (480)
      #   margin: deadline >= delivery + window - jitter
      #                     = dispatch + transport + 320
      #
      # At transport=100 that demands deadline <= 480 AND >= 420 — the
      # only satisfiable one of the three — and at transport=200 it
      # demands deadline <= 480 AND >= 520. Two of the three rows in
      # this very test were unsatisfiable by ANY implementation, which
      # is why it could never have gone green as written.
      #
      # The replacement is the same claim about the anchor, made about
      # the anchor the fix installs: the deadline is one window after
      # DELIVERY. It is strictly stronger than the margin assertion
      # below (which only bounds the deadline from one side), so this
      # is not a weakening — it pins the anchor rather than merely
      # requiring the responder not be short-changed.
      for m <- measurements do
        assert_in_delta m.dispatch_to_deadline_ms, m.delivery_ms + @window_ms, @jitter_ms
      end

      # The defect: the responder is left with window - transport.
      for m <- measurements do
        assert m.margin_ms >= @window_ms - @jitter_ms,
               "intent #{m.intent_id} was delivered #{m.delivery_ms}ms after dispatch and " <>
                 "had only #{m.margin_ms}ms of its #{@window_ms}ms window left. " <>
                 "A responder cannot be held to time it never had."
      end
    end

    test "a burst of five gets a flat margin, not a degrading one — the window is not cascading",
         %{meeting_id: meeting_id} do
      # The ticket's own hypothesis is that one slow intent eats the
      # next one's window, so margin degrades across a burst. The
      # queue's serial cursor makes that plausible. Measure it.
      transport_ms = div(@window_ms, 2)

      # Enqueue the whole burst FIRST, so the queue actually reaches
      # depth #{@burst_size} and rows 2..#{@burst_size} really are
      # head-of-line blocked behind row 1. Draining one row at a time
      # while enqueueing one row at a time would never exceed depth 1
      # and could not surface a cascade at all.
      rows = for _ <- 1..@burst_size, do: enqueue!(meeting_id)

      assert length(IntentQueue.list(meeting_id)) == @burst_size

      measurements =
        Enum.map(rows, fn row -> dispatch_and_measure(meeting_id, row, transport_ms) end)

      report("margin across a burst of #{@burst_size}", measurements)

      margins = Enum.map(measurements, & &1.margin_ms)
      first = List.first(margins)
      last = List.last(margins)

      # No slope: head-of-line blocking would show the last intent
      # getting materially less time than the first. Each intent's
      # timer is armed at its OWN `:dispatched` transition, so a
      # blocked intent gets a full fresh window when it finally goes
      # out. Blocking makes an intent arrive LATE, not SHORT.
      assert_in_delta last,
                      first,
                      @jitter_ms,
                      "margin degraded across the burst (#{inspect(margins)}) — that would be " <>
                        "head-of-line blocking, a different defect needing a different fix"

      # What head-of-line blocking DOES do, stated as a measured fact
      # rather than left as an inference: each queued intent waits for
      # every intent ahead of it, so creation->dispatch grows by about
      # one window per position. The blocked intent is STALE — the
      # meeting has moved on — but its window is untouched, because the
      # timer is armed at its own `:dispatched` transition. Stale and
      # short are different defects with different fixes, and this
      # ticket's evidence is the short one.
      staleness = Enum.map(measurements, & &1.creation_to_dispatch_ms)

      assert List.last(staleness) - List.first(staleness) >=
               (@burst_size - 1) * (@window_ms - @jitter_ms),
             "expected the burst to serialise, so later intents dispatch progressively later " <>
               "(creation->dispatch was #{inspect(staleness)}) — if it did not, the rows were " <>
               "not actually queued behind one another and the flat margin above proves nothing"

      # ... and yet every one of them is short, by the same constant
      # amount. A flat deficit is an anchor bug, not a queue bug.
      for {m, i} <- Enum.with_index(measurements, 1) do
        assert m.margin_ms >= @window_ms - @jitter_ms,
               "burst position #{i} had #{m.margin_ms}ms of its #{@window_ms}ms window left"
      end
    end
  end

  # ── The ticket's cleanest case ─────────────────────────────────────────────

  describe "a maximally fast responder" do
    test "`working` sent as the very first action after delivery is still refused", %{
      meeting_id: meeting_id
    } do
      # The field case this ticket is built on: `status: "working"` — the
      # documented way to stop the clock while you do the work — sent as
      # the responder's first tool call, and refused. Here the responder
      # does no work at all: it acks on the same scheduler run that
      # delivery lands. There is no faster possible response.
      row = enqueue!(meeting_id)
      {:ok, _} = IntentQueue.claim_next(meeting_id)
      {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)

      intent_id = row.id
      assert_receive {:intent_dispatched, %{id: ^intent_id}}, @window_ms + 2_000
      t_dispatch = mono_ms()

      # Transport costs slightly more than the window — the shape the
      # ticket reports, where the dispatch reaches the agent after its
      # window has already closed.
      transport_ms = @window_ms + 100
      Process.send_after(self(), {:delivered, intent_id}, transport_ms)
      assert_receive {:delivered, ^intent_id}, transport_ms + 2_000
      t_delivery = mono_ms()

      result = IntentQueue.ack(meeting_id, intent_id, "sub-1", :working)

      IO.puts(
        "\n  first-action `working` ack: delivered +#{t_delivery - t_dispatch}ms after " <>
          "dispatch, window=#{@window_ms}ms, ack result=#{inspect(result)}\n"
      )

      assert {:ok, acked} = result,
             "a `working` ack sent as the responder's first action after delivery was " <>
               "refused with #{inspect(result)} — the responder was charged for #{transport_ms}ms " <>
               "of transport it neither caused nor could observe"

      assert acked.status == :acked
    end
  end

  # ── The trap the fix has to avoid (task 019ff292 stage 2) ──────────────────

  describe "the outer, transmission-anchored bound" do
    # If the responder's window were the ONLY clock, an intent that
    # reached nobody would never start one — and would hold the serial
    # cursor for the rest of the meeting, starving every intent behind
    # it on that meeting. That is a worse bug than the one being fixed,
    # so this is the assertion that keeps the fix honest.
    #
    # Delete `phase_for_status(:dispatched) -> :awaiting_delivery` (or
    # the `:awaiting_delivery` arm of the timeout handler) and this
    # test hangs at the `assert_receive` and fails: nothing else in the
    # queue would ever resolve the row.
    test "an intent nobody ever received still terminates and releases the cursor", %{
      meeting_id: meeting_id
    } do
      outer_ms = Server.delivery_timeout_ms(meeting_id)

      # The bound has to be strictly longer than the responder's
      # window, or it subsumes it and re-anchoring buys nothing.
      assert outer_ms > @window_ms

      row = enqueue!(meeting_id)
      {:ok, _} = IntentQueue.claim_next(meeting_id)
      {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)

      intent_id = row.id
      assert_receive {:intent_dispatched, %{id: ^intent_id} = dispatched}, @window_ms + 2_000
      t_dispatch = mono_ms()

      # Nothing is sent. No `mark_delivered`, no ack — this is the
      # broadcast-into-the-void case: no runtime subscribed, agent
      # offline, or a client that does not speak `intent_delivered`.
      #
      # It must NOT resolve at the responder's window. That window
      # belongs to a responder, and there is no evidence one exists.
      refute_receive {:intent_timed_out, %{id: ^intent_id}}, @window_ms + @jitter_ms

      assert_receive {:intent_timed_out, timed_out}, outer_ms + 2_000
      held_ms = mono_ms() - t_dispatch

      assert timed_out.id == intent_id
      assert timed_out.status == :timed_out
      assert is_nil(timed_out.delivered_at)

      # Amber, but it says WHY: an operator can tell "reached nobody"
      # from "reached someone who then went quiet", which are different
      # things to go and fix.
      assert timed_out.dispatch_failure_reason == :never_delivered

      # The hold is read off the server's own stamps, not this process's
      # clock (task 01a1486f). `dispatched_at` is stamped on the single
      # write path just before the outer timer is armed, and
      # `timed_out_at` inside the timer's handler, so their difference is
      # the bound the server actually ran. The test-process `held_ms`
      # also carries two `assert_receive` wake-ups — CI run 39004184961
      # measured 1003ms against an 800ms bound that way — and is kept
      # only as a reported figure, so a stress log shows where any excess
      # lives.
      #
      # BOTH sides of the delta stay: the `refute_receive` above only
      # covers the first `@window_ms + @jitter_ms` after dispatch, so an
      # outer bound firing early but after that window is caught only by
      # the lower side here.
      #
      # Known limit: this still includes the queue server's own latency
      # in handling the timer message. It removes the test process from
      # the measurement, not the server.
      server_held_ms =
        DateTime.diff(timed_out.timed_out_at, dispatched.dispatched_at, :millisecond)

      IO.puts(
        "\n  never-delivered hold: server_held_ms=#{server_held_ms} " <>
          "test_process_held_ms=#{held_ms} outer_ms=#{outer_ms} jitter_ms=#{@jitter_ms}\n"
      )

      assert_in_delta server_held_ms,
                      outer_ms,
                      @jitter_ms,
                      "the outer bound held a never-delivered intent for #{server_held_ms}ms by the " <>
                        "server's own dispatched_at/timed_out_at stamps, expected " <>
                        "#{outer_ms}ms +/- #{@jitter_ms}ms (test-process view: #{held_ms}ms)"

      # The whole point: the meeting is free again.
      assert IntentQueue.cursor(meeting_id) == nil

      next = enqueue!(meeting_id)
      assert {:ok, claimed} = IntentQueue.claim_next(meeting_id)
      assert claimed.id == next.id
    end

    test "a receipt arriving after the outer bound gave up is refused, not revived", %{
      meeting_id: meeting_id
    } do
      row = enqueue!(meeting_id)
      {:ok, _} = IntentQueue.claim_next(meeting_id)
      {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)

      intent_id = row.id

      assert_receive {:intent_timed_out, %{id: ^intent_id}},
                     Server.delivery_timeout_ms(meeting_id) + 2_000

      # The cursor has moved on. Re-anchoring a resolved row would put
      # a second intent in front of the same agent — exactly what the
      # serial cursor exists to prevent — so a late receipt is an
      # error, and a loud one.
      assert {:error, {:not_deliverable, :timed_out}} =
               IntentQueue.mark_delivered(meeting_id, intent_id)

      assert {:ok, %{status: :timed_out, delivered_at: nil}} =
               IntentQueue.get(meeting_id, intent_id)

      assert IntentQueue.cursor(meeting_id) == nil
    end
  end

  describe "first contact is recorded once" do
    # A runtime that resends the receipt — a retry, a reconnect, a
    # chatty client — must not be able to hold the serial cursor open
    # indefinitely by re-arming the window on every repeat. Only a
    # `:working` ack, which is a claim about a subagent that exists,
    # buys a fresh window.
    test "a repeated receipt does not buy a second window", %{meeting_id: meeting_id} do
      row = enqueue!(meeting_id)
      {:ok, _} = IntentQueue.claim_next(meeting_id)
      {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)

      intent_id = row.id
      assert_receive {:intent_dispatched, %{id: ^intent_id}}, @window_ms + 2_000

      {:ok, first} = IntentQueue.mark_delivered(meeting_id, intent_id)
      t_first_contact = mono_ms()
      assert %DateTime{} = first.delivered_at

      assert_receive {:intent_delivered, %{id: ^intent_id}}, 2_000

      # Resend it well into the window. A re-arm here would push the
      # deadline out to roughly `2 x window` after first contact.
      repeat_after_ms = div(@window_ms, 2)
      Process.send_after(self(), :resend, repeat_after_ms)
      assert_receive :resend, repeat_after_ms + 2_000

      assert {:ok, repeated} = IntentQueue.mark_delivered(meeting_id, intent_id)
      assert repeated.delivered_at == first.delivered_at

      assert_receive {:intent_timed_out, %{id: ^intent_id} = timed_out}, @window_ms * 3
      held_ms = mono_ms() - t_first_contact

      # The hold is read off the server's own stamps, not this process's
      # clock (task 01a1486f, as for the never-delivered case above).
      # `delivered_at` is stamped on first contact just before the
      # `:awaiting_ack` timer is armed, and `timed_out_at` inside that
      # timer's handler, so their difference is the window the server
      # actually ran. The test-process `held_ms` also carries the
      # `assert_receive` wake-up for the timeout broadcast, so it is
      # kept only as a reported figure.
      #
      # BOTH sides of the delta stay: a re-arm on the repeat moves the
      # deadline out (upper side), and a window that closes early is
      # caught only by the lower side.
      #
      # Known limit: this still includes the queue server's own latency
      # in handling the timer message.
      server_held_ms =
        DateTime.diff(timed_out.timed_out_at, first.delivered_at, :millisecond)

      IO.puts(
        "\n  repeated-receipt hold: server_held_ms=#{server_held_ms} " <>
          "test_process_held_ms=#{held_ms} window_ms=#{@window_ms} jitter_ms=#{@jitter_ms}\n"
      )

      assert_in_delta server_held_ms,
                      @window_ms,
                      @jitter_ms,
                      "the deadline moved with the repeated receipt (#{server_held_ms}ms after " <>
                        "first contact by the server's own delivered_at/timed_out_at stamps, " <>
                        "window=#{@window_ms}ms +/- #{@jitter_ms}ms, test-process view: " <>
                        "#{held_ms}ms) — a runtime could hold the meeting's serial cursor open " <>
                        "by resending it"
    end

    # `status: "working"` is the documented way to stop the clock, and
    # it is the ONLY signal a client that does not yet send
    # `intent_delivered` can offer. It has to count as first contact on
    # its own, or every existing runtime is left exactly where it was.
    test "a `working` ack is first contact on its own, with no receipt at all", %{
      meeting_id: meeting_id
    } do
      row = enqueue!(meeting_id)
      {:ok, _} = IntentQueue.claim_next(meeting_id)
      {:ok, _} = IntentQueue.transition(meeting_id, row.id, :dispatched)

      intent_id = row.id
      assert_receive {:intent_dispatched, %{id: ^intent_id}}, @window_ms + 2_000

      # Later than the responder's window, inside the outer bound: the
      # field shape, from a client that never learned to receipt.
      transport_ms = @window_ms + 100
      assert transport_ms < Server.delivery_timeout_ms(meeting_id)

      Process.send_after(self(), :delivered, transport_ms)
      assert_receive :delivered, transport_ms + 2_000

      assert {:ok, acked} = IntentQueue.ack(meeting_id, intent_id, "sub-legacy", :working)
      assert acked.status == :acked
      t_ack = mono_ms()

      # And the clock it stopped restarts HERE, not at transmission —
      # the responder gets its whole window to do the work it just said
      # it had started.
      assert_receive {:intent_timed_out, %{id: ^intent_id}}, @window_ms * 3
      margin_ms = mono_ms() - t_ack

      assert margin_ms >= @window_ms - @jitter_ms,
             "a responder that acked `working` #{transport_ms}ms after dispatch got only " <>
               "#{margin_ms}ms of its #{@window_ms}ms window"
    end
  end
end
