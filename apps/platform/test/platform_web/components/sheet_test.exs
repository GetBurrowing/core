defmodule PlatformWeb.Components.SheetTest do
  @moduledoc """
  Stage 1 unit tests for the new <.sheet> component.

  Task: 019e0d4b — Build <.sheet> component + migrate drawer/sheet sites.
  Spec: docs/design-system/components/sheet.md

  Verifies the rendered DOM contract that the JS hook + migration sites depend on:
  required attrs, the `data-open` flag flip, placement classes, slot rendering,
  and the close-button event wiring. JS focus-management behavior is verified
  end-to-end in Stage 4 (e2e_behavior validations) — not in this unit slice.
  """

  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.Sheet

  defp render_sheet(assigns) do
    assigns =
      Map.merge(
        %{
          id: "test-sheet",
          open: false,
          placement: :bottom,
          on_close: "close_sheet",
          class: nil,
          title: nil,
          actions: nil
        },
        assigns
      )

    rendered =
      rendered_to_string(~H"""
      <.sheet
        id={@id}
        open={@open}
        placement={@placement}
        on_close={@on_close}
        class={@class}
      >
        <:title :if={@title}>{@title}</:title>
        <:actions :if={@actions}>{@actions}</:actions>
        <p>body content</p>
      </.sheet>
      """)

    rendered
  end

  describe "sheet/1 — required structure" do
    test "renders dialog role + aria-modal + aria-labelledby" do
      html = render_sheet(%{})
      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-modal="true")
      assert html =~ ~s(aria-labelledby="test-sheet-title")
    end

    test "wires phx-hook=Sheet on the root element" do
      html = render_sheet(%{})
      assert html =~ ~s(phx-hook="Sheet")
    end

    test "renders body slot content" do
      html = render_sheet(%{})
      assert html =~ "body content"
    end
  end

  describe "sheet/1 — :open flag" do
    test "data-open='false' when :open is false (and no .sheet-open class)" do
      html = render_sheet(%{open: false})
      assert html =~ ~s(data-open="false")
      refute html =~ "sheet-open"
    end

    test "data-open='true' when :open is true (and .sheet-open class lands)" do
      html = render_sheet(%{open: true})
      assert html =~ ~s(data-open="true")
      assert html =~ "sheet-open"
    end
  end

  describe "sheet/1 — :placement" do
    for placement <- [:bottom, :right, :left, :top] do
      test "placement=#{placement} adds the .sheet-#{placement} class" do
        html = render_sheet(%{placement: unquote(placement)})
        assert html =~ "sheet-#{unquote(placement)}"
      end
    end

    test "placement=:bottom renders the drag handle" do
      html = render_sheet(%{placement: :bottom})
      assert html =~ ~s(class="sheet-handle")
    end

    test "non-bottom placement omits the drag handle" do
      html = render_sheet(%{placement: :right})
      refute html =~ ~s(class="sheet-handle")
    end
  end

  describe "sheet/1 — :on_close wiring" do
    test "default on_close=\"close_sheet\" is attached to the close button" do
      html = render_sheet(%{})
      # The close button has aria-label=Close and phx-click=close_sheet
      assert html =~ ~s(aria-label="Close")
      assert html =~ ~s(phx-click="close_sheet")
    end

    test "custom on_close gets attached to backdrop AND close button" do
      html = render_sheet(%{on_close: "dismiss_thing"})
      assert html =~ ~s(phx-click="dismiss_thing")
      assert html =~ ~s(data-on-close="dismiss_thing")
    end
  end

  describe "sheet/1 — slots" do
    test "title slot renders inside the labelled <h2>" do
      html = render_sheet(%{title: "My Sheet Title"})
      assert html =~ "My Sheet Title"
      assert html =~ ~s(id="test-sheet-title")
    end

    test "actions slot renders the footer when provided" do
      html = render_sheet(%{actions: "Save"})
      assert html =~ "sheet-actions"
      assert html =~ "Save"
    end

    test "actions slot omitted = no footer rendered" do
      html = render_sheet(%{actions: nil})
      refute html =~ "sheet-actions"
    end
  end

  describe "sheet/1 — :class extension" do
    test "extra class is appended to the root element" do
      html = render_sheet(%{class: "lg:hidden custom-thing"})
      # Both the base classes AND the custom classes should land on the root <div>.
      assert html =~ "lg:hidden"
      assert html =~ "custom-thing"
      assert html =~ "sheet"
    end

    test "nil class doesn't break rendering" do
      html = render_sheet(%{class: nil})
      assert html =~ "sheet"
    end
  end
end
