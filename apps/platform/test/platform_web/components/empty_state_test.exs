defmodule PlatformWeb.Components.EmptyStateTest do
  @moduledoc """
  Stage 1 unit tests for the new <.empty_state> component.

  Task: 019e0d4b-9576 — Build <.empty_state> component + migrate empty surfaces.
  Spec: docs/design-system/components/empty_state.md

  Verifies the rendered DOM contract per variant: outer class, slot rendering,
  optional-slot omission, chip event wiring. Visual end-to-end (per-surface
  copy verbatim, conversational chrome doesn't leak into Activity) is
  validated in Stage 3 e2e_behavior cases.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.EmptyState

  describe "empty_state/1 — :minimal variant" do
    test "renders .empty-minimal outer class with body content" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.empty_state variant={:minimal}>
          <:body>When your agents start working, what they do appears here.</:body>
        </.empty_state>
        """)

      assert html =~ "empty-state"
      assert html =~ "empty-minimal"
      assert html =~ "When your agents start working, what they do appears here."
    end

    test ":minimal does NOT render conversational chrome (Marlowe pin regression check)" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.empty_state variant={:minimal}>
          <:body>activity-style copy</:body>
        </.empty_state>
        """)

      # The Marlowe 2026-05-09 pin: Activity uses :minimal; conversational chrome
      # (bot bubble, system message, chips) must NOT leak in. This test would fail
      # if a regression accidentally swapped the variant or rendered both.
      refute html =~ "empty-bot-bubble"
      refute html =~ "empty-system-msg"
      refute html =~ "empty-chip"
      refute html =~ "Saru"
    end
  end

  describe "empty_state/1 — :standard variant" do
    test "renders .empty-standard outer class + body" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.empty_state variant={:standard}>
          <:body>generic empty body text</:body>
        </.empty_state>
        """)

      assert html =~ "empty-standard"
      assert html =~ "generic empty body text"
    end

    test ":standard with icon_name renders the icon wrapper + heroicon span" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.empty_state variant={:standard} icon_name="hero-magnifying-glass">
          <:body>no body</:body>
        </.empty_state>
        """)

      assert html =~ "empty-icon-wrapper"
      assert html =~ "hero-magnifying-glass"
    end

    test ":standard without icon_name omits the icon wrapper" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.empty_state variant={:standard}>
          <:body>no body</:body>
        </.empty_state>
        """)

      refute html =~ "empty-icon-wrapper"
    end

    test ":standard with title slot renders the <h2>" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.empty_state variant={:standard}>
          <:title>No matches</:title>
          <:body>No messages match.</:body>
        </.empty_state>
        """)

      assert html =~ "empty-title"
      assert html =~ "No matches"
      assert html =~ ~r{<h2[^>]*>}
    end

    test ":standard without title slot omits the <h2>" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.empty_state variant={:standard}>
          <:body>no title</:body>
        </.empty_state>
        """)

      refute html =~ "empty-title"
    end

    test ":standard with actions slot renders the actions container" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.empty_state variant={:standard}>
          <:body>body</:body>
          <:actions>
            <button>Clear search</button>
          </:actions>
        </.empty_state>
        """)

      assert html =~ "empty-actions"
      assert html =~ "Clear search"
    end

    test ":standard without actions slot omits the actions container" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.empty_state variant={:standard}>
          <:body>body only</:body>
        </.empty_state>
        """)

      refute html =~ "empty-actions"
    end
  end

  describe "empty_state/1 — :conversational variant" do
    test "renders .empty-conversational outer class + bot bubble + 'Saru · suggested' label" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.empty_state variant={:conversational}>
          <:body>Welcome to Burrow.</:body>
        </.empty_state>
        """)

      assert html =~ "empty-conversational"
      assert html =~ "empty-bot-bubble"
      assert html =~ "empty-bot-author"
      assert html =~ "Saru · suggested"
      assert html =~ "Welcome to Burrow."
    end

    test ":conversational with system_message slot renders the system pill" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.empty_state variant={:conversational}>
          <:system_message>— no spaces yet —</:system_message>
          <:body>Welcome.</:body>
        </.empty_state>
        """)

      assert html =~ "empty-system-msg"
      assert html =~ "— no spaces yet —"
    end

    test ":conversational without system_message omits the system pill" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.empty_state variant={:conversational}>
          <:body>Welcome.</:body>
        </.empty_state>
        """)

      refute html =~ "empty-system-msg"
    end

    test ":conversational chips render as <button> elements with phx-click and visible label" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.empty_state variant={:conversational}>
          <:body>Welcome.</:body>
          <:chips label="+ Create a space" event="open_create_space_sheet" />
          <:chips label="+ Connect an agent" event="open_connect_agent_sheet" />
        </.empty_state>
        """)

      # Each chip is a button with the event wired and the label as visible text.
      assert html =~ ~s(phx-click="open_create_space_sheet")
      assert html =~ ~s(phx-click="open_connect_agent_sheet")
      assert html =~ "+ Create a space"
      assert html =~ "+ Connect an agent"
      assert html =~ "empty-chip"
    end

    test ":conversational with no chips renders no chip buttons" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.empty_state variant={:conversational}>
          <:body>just a bubble</:body>
        </.empty_state>
        """)

      refute html =~ "empty-chip"
    end
  end
end
