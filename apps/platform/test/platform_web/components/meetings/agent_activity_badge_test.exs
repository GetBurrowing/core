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
end
