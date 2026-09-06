defmodule PlatformWeb.Components.Meetings.AgentActivityBadgeTest do
  @moduledoc """
  The render half of the agent dock's states.

  The defect this closes is not "the badge shows the wrong thing" — it
  is that the surface could only show ONE thing. `agent_status_dot_class/3`
  mapped every non-idle state to `bg-success`, so `AgentActivity`
  resolved `:typing`, `:computing` and `:failed` apart and the screen
  threw the distinction away at the last step.

  A test that renders one state and asserts its word appears is
  therefore worthless here: it was green throughout the entire life of
  the bug. Every assertion below renders at least TWO states and asserts
  the outputs DIFFER.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PlatformWeb.Components.Meetings.AgentActivityBadge

  defp badge(state, name \\ "Saru") do
    render_component(&AgentActivityBadge.agent_activity_badge/1, state: state, name: name)
  end

  describe "the three real states" do
    # The load-bearing test. This is the assertion the old dot could
    # never have passed.
    test "render three DIFFERENT outputs" do
      thinking = badge(:computing)
      writing = badge(:typing)
      couldnt = badge(:failed)

      assert thinking =~ "Thinking"
      assert writing =~ "Writing"
      assert couldnt =~ "Couldn&#39;t"

      assert MapSet.size(MapSet.new([thinking, writing, couldnt])) == 3
    end

    # Colour alone is a few pixels at avatar size and invisible to a
    # colourblind viewer, so the word must be real text — not a `title`
    # attribute that only exists on hover.
    test "carry the word as text, not only as colour" do
      html = badge(:failed)

      assert html =~ ~s(data-role="agent-activity-word")
      assert html =~ "Couldn&#39;t"
    end

    test "carry a distinct glyph as well as a distinct colour" do
      thinking = badge(:computing)
      writing = badge(:typing)

      assert thinking =~ "◐"
      assert writing =~ "✎"
      refute thinking =~ "✎"
      refute writing =~ "◐"
    end

    # Saru's ruling (canvas 01a05b11-54ff card 6, 2026-09-02): Thinking
    # and Writing share the `info` slot, and MOTION is what tells them
    # apart — Thinking is static, Writing moves. A pulse also reads as
    # "still going", which is the opposite of what `:failed` says, so
    # the cap never moves either. Only Writing animates.
    test "only Writing animates: motion, not colour, separates it from Thinking" do
      refute badge(:computing) =~ "animate-pulse"
      assert badge(:typing) =~ "animate-pulse"
      refute badge(:failed) =~ "animate-pulse"
    end

    # The token swap itself. `warning` on this screen now means one
    # thing — a human is being asked for something (the invite banner)
    # — and a working agent must never borrow it.
    test "Writing sits on info, not on the invite banner's warning slot" do
      writing = badge(:typing)

      assert writing =~ "border-info"
      assert writing =~ "text-info"
      refute writing =~ "warning"
    end

    test "name the agent in the accessible label" do
      assert badge(:failed, "AgentVoice") =~ "AgentVoice is Couldn&#39;t"
    end
  end

  describe "states with no producer" do
    # `:listening` is declared in `AgentActivity` and nothing can set
    # it. Drawing it would put a caption on screen that is always false.
    # Asserted rather than commented so adding a producer forces a
    # deliberate edit here.
    test ":listening renders as idle, not as a label that can never be true" do
      assert :listening in Platform.Meetings.AgentActivity.states()
      refute :listening in Platform.Meetings.AgentActivity.signals()

      # Compared on the VISUAL output. `data-activity-state` legitimately
      # differs — it echoes the input — so it is normalised away rather
      # than allowed to make this pass for the wrong reason.
      strip_state = &String.replace(&1, ~r/data-activity-state="[a-z_]+"/, "")

      assert strip_state.(badge(:listening)) == strip_state.(badge(:idle))
      refute badge(:listening) =~ "Listening"
      refute badge(:listening) =~ ~s(data-role="agent-activity-word")
    end

    test "idle carries no word at all" do
      html = badge(:idle)

      refute html =~ ~s(data-role="agent-activity-word")
      refute html =~ "Thinking"
      refute html =~ "Writing"
      refute html =~ "Couldn"
    end
  end

  test "every state exposes itself for assertion and styling" do
    for state <- [:computing, :typing, :failed, :idle] do
      assert badge(state) =~ ~s(data-activity-state="#{state}")
    end
  end

  # `:heard` (task 01a06e07 stage 2 gave it a producer and a decay;
  # stage 3 gives it a row in this ONE table, per the stage's own
  # constraint — a second mapping was explicitly ruled out). Same shape
  # of test as "render three DIFFERENT outputs" above: rendering one
  # state and asserting its word appears would have been green even if
  # `:heard` had silently fallen through to `:idle`'s presentation, which
  # is exactly what it did before this row existed.
  describe "the Heard receipt" do
    test "renders its OWN word and glyph, distinct from every other state" do
      heard = badge(:heard)
      thinking = badge(:computing)
      idle = badge(:idle)

      assert heard =~ "Heard"
      assert heard =~ ~s(data-activity-state="heard")
      refute heard == idle
      refute heard == thinking

      assert MapSet.size(MapSet.new([heard, thinking, idle])) == 3
    end

    test "sits on the info slot, like Thinking and Writing — never warning" do
      heard = badge(:heard)

      assert heard =~ "border-info"
      assert heard =~ "text-info"
      refute heard =~ "warning"
    end

    test "its ring pulses, unlike Thinking's" do
      assert badge(:heard) =~ "animate-pulse"
      refute badge(:computing) =~ "animate-pulse"
    end
  end

  # ── task 01a07400 stage 3: Speaking, Delayed, and the reduced-motion half ──
  #
  # Saru's design direction (canvas 01a07402-99e3) makes MOTION the liveness
  # axis — "colour answers does this need me, motion answers is it
  # progressing" — and then rules that the design must not collapse for a
  # reader who has asked for less of it. These tests are that ruling.
  describe "the states this stage adds" do
    # The glyph inside the ring node, as rendered.
    defp glyph_of(state) do
      state
      |> badge()
      |> Floki.parse_fragment!()
      |> Floki.find(~s([data-role="agent-activity-ring"]))
      |> Floki.text()
      |> String.trim()
    end

    # ── THE ANTI-VACUITY TEST ────────────────────────────────────────────
    #
    # `app.css` disables every animation in the app under
    # `prefers-reduced-motion`, so under that preference this component
    # renders the SAME markup with the motion inert. A test that asserted
    # "no animation class is present" would therefore be worthless twice
    # over: it describes a branch that does not exist, and it passes just as
    # happily on a row that renders nothing at all.
    #
    # What actually has to hold is that the glyph — the channel that still
    # works when motion is off — tells the states apart on its own. So this
    # asserts the glyphs are pairwise DISTINCT and each non-empty. It fails
    # if any two states share a mark, which was verified by mutation: giving
    # `:delayed` `:speaking`'s `●` turns it red.
    test "every distinguishable state carries a DIFFERENT, non-empty glyph" do
      # `:idle` is excluded and only `:idle`: its glyph is deliberately the
      # empty string (an idle agent carries no mark), which is itself the
      # distinction. `:listening` is excluded because it has no producer and
      # must not gain a clause — canvas 01a07402-99e3 says so in as many
      # words. Everything else that can reach a screen is in this list.
      states = [:computing, :typing, :heard, :speaking, :delayed, :failed]
      glyphs = Enum.map(states, &glyph_of/1)

      assert length(glyphs) == 6,
             "a state was added or dropped without updating the reduced-motion guard"

      for {state, glyph} <- Enum.zip(states, glyphs) do
        refute glyph == "",
               "#{inspect(state)} has no glyph, so it is invisible under prefers-reduced-motion"
      end

      assert Enum.uniq(glyphs) == glyphs,
             "two states share a glyph, so reduced motion cannot tell them apart: " <>
               inspect(Enum.zip(states, glyphs))
    end

    # The pair the axis would otherwise be ALONE in separating: both are
    # live-ish working readings, and the difference between them under
    # normal motion is that one moves and one has stopped. Called out on its
    # own because it is the case the set-level assertion above exists for,
    # and a set assertion can drift into passing for unrelated reasons.
    test "Speaking and Delayed are told apart without motion at all" do
      refute glyph_of(:speaking) == glyph_of(:delayed)

      # ...and not only by the glyph: the ring colour differs too, so the
      # two static channels agree rather than resting on one.
      assert badge(:speaking) =~ "border-success"
      assert badge(:delayed) =~ "border-base-content/25"
    end

    test "Speaking takes the success slot the ratified map assigns to live audio" do
      speaking = badge(:speaking)

      assert speaking =~ "Speaking"
      assert speaking =~ "border-success"
      assert speaking =~ "text-success"
      refute speaking =~ "warning"
    end

    # "Amplitude, not a pulse" — the canvas reserves the pulse for Writing,
    # where it reads as the pen moving. Asserting the two motions DIFFER is
    # the assertion; asserting one class is present would pass with both
    # states on the same animation.
    test "Speaking moves by amplitude, and Writing's pulse is not reused for it" do
      speaking = badge(:speaking)

      assert speaking =~ "agent-activity-ring-speaking"
      refute speaking =~ "animate-pulse"
      assert badge(:typing) =~ "animate-pulse"
      refute badge(:typing) =~ "agent-activity-ring-speaking"
    end

    # The one state that splits its two colour slots, which is the whole
    # idea: still working (word keeps `info`), not progressing (ring drains
    # to the neutral value `:idle` uses).
    test "Delayed keeps info for its word and drains its ring to neutral" do
      delayed = badge(:delayed)
      parsed = Floki.parse_fragment!(delayed)

      word_class =
        parsed
        |> Floki.find(~s([data-role="agent-activity-word"]))
        |> Floki.attribute("class")
        |> List.first()

      ring_class =
        parsed
        |> Floki.find(~s([data-role="agent-activity-ring"]))
        |> Floki.attribute("class")
        |> List.first()

      assert delayed =~ "Delayed"
      assert word_class =~ "text-info", "the word must stay on the working family's slot"
      refute ring_class =~ "border-info", "the ring is the liveness channel and must drain"
      assert ring_class =~ "border-base-content/25"
    end

    # The hard-won rule on this surface: `warning` means a human is being
    # asked for something, and a blocked agent asks nothing of anyone.
    # Settled after five stages reported it open, so it gets its own guard.
    test "Delayed refuses the warning slot, and refuses to spin" do
      delayed = badge(:delayed)

      refute delayed =~ "warning"
      refute delayed =~ "animate-pulse"
      refute delayed =~ "animate-spin"
      refute delayed =~ "agent-activity-ring-speaking"
    end

    # `:thinking` and `:composing` are what a federated runtime declares
    # about ITSELF (task 01a07400 stage 1). They are drawn as exact aliases
    # of the states core observes for the same message, because the canvas
    # gives one appearance per message and the reader cannot act on which
    # side produced it.
    #
    # Asserting equality of the WHOLE rendered fragment except the state
    # attribute is deliberate: it detonates if either row drifts, which a
    # per-field assertion would not.
    test "the two pushed states render exactly as the observed states they mirror" do
      assert String.replace(badge(:thinking), ~s(state="thinking"), ~s(state="computing")) ==
               badge(:computing)

      assert String.replace(badge(:composing), ~s(state="composing"), ~s(state="typing")) ==
               badge(:typing)
    end

    # ...but they must stay TELLABLE APART in the DOM, or a screenshot diff
    # and a test both lose the ability to say which producer spoke. This is
    # what keeps the clause above an alias rather than a silent collapse.
    test "the pushed states stay identifiable in the DOM despite rendering alike" do
      assert badge(:thinking) =~ ~s(data-activity-state="thinking")
      assert badge(:composing) =~ ~s(data-activity-state="composing")
    end

    # `:listening` is the trap this ticket names by hand. It has no producer,
    # it was removed from the rail by a ratified decision, and canvas
    # 01a07402-99e3 WITHDREW its own earlier suggestion to restore it: "Do
    # not add a `meta(:listening)` clause as part of this work."
    test "Listening still has no visual of its own" do
      assert String.replace(badge(:listening), ~s(state="listening"), ~s(state="idle")) ==
               badge(:idle)
    end
  end
end
