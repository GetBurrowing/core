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

  # Task 01a1557a-807f stage 4: written and shown green BEFORE `handle_close`
  # and `swipe_dismiss` existed. The twelve call sites that pass neither must
  # keep exactly this markup.
  describe "sheet/1 — default markup (no opt-ins)" do
    test "decorative aria-hidden handle, header X button, visible title, no swipe stamp" do
      html = render_sheet(%{open: true, title: "Title"})
      doc = LazyHTML.from_fragment(html)

      handle = LazyHTML.query(doc, ".sheet-panel > div.sheet-handle")
      assert Enum.count(handle) == 1
      assert LazyHTML.attribute(handle, "aria-hidden") == ["true"]
      assert LazyHTML.query(doc, ".sheet-handle-button") |> Enum.count() == 0
      assert LazyHTML.query(doc, "button.sheet-handle") |> Enum.count() == 0

      close = LazyHTML.query(doc, ~s(header.sheet-header button[aria-label="Close"]))
      assert Enum.count(close) == 1
      assert LazyHTML.attribute(close, "phx-click") == ["close_sheet"]

      [title_class] = doc |> LazyHTML.query("h2#test-sheet-title") |> LazyHTML.attribute("class")
      assert title_class == "sheet-title"
      refute title_class =~ "sr-only"

      assert doc |> LazyHTML.query("[data-swipe-dismiss]") |> Enum.count() == 0
    end
  end

  describe "sheet/1 — handle_close and swipe_dismiss opt-ins (task 01a1557a-807f stage 4)" do
    defp render_opted(attrs) do
      assigns = Map.merge(%{handle_close: false, swipe_dismiss: false}, attrs)

      rendered_to_string(~H"""
      <.sheet
        id="opt-sheet"
        open={true}
        on_close="close_more_sheet"
        handle_close={@handle_close}
        swipe_dismiss={@swipe_dismiss}
      >
        <:title>More</:title>
        <p>body</p>
      </.sheet>
      """)
      |> LazyHTML.from_fragment()
    end

    test "handle_close: the handle is a Close button; no X; the title is visually hidden" do
      doc = render_opted(%{handle_close: true})

      button = LazyHTML.query(doc, ".sheet-panel > button.sheet-handle-button")
      assert Enum.count(button) == 1
      assert LazyHTML.attribute(button, "type") == ["button"]
      assert LazyHTML.attribute(button, "aria-label") == ["Close"]
      assert LazyHTML.attribute(button, "phx-click") == ["close_more_sheet"]
      # The visible 36x4 bar is still there, inside, decorative.
      assert button |> LazyHTML.query(".sheet-handle[aria-hidden=true]") |> Enum.count() == 1
      # Exactly one Close control: the handle.
      assert doc |> LazyHTML.query(~s(button[aria-label="Close"])) |> Enum.count() == 1
      assert doc |> LazyHTML.query("header .sheet-close-button") |> Enum.count() == 0

      [title_class] = doc |> LazyHTML.query("h2#opt-sheet-title") |> LazyHTML.attribute("class")
      assert title_class =~ "sr-only"
      assert doc |> LazyHTML.query("h2#opt-sheet-title") |> LazyHTML.text() =~ "More"

      assert LazyHTML.attribute(LazyHTML.query(doc, "#opt-sheet"), "aria-labelledby") == [
               "opt-sheet-title"
             ]

      assert doc |> LazyHTML.query("[data-swipe-dismiss]") |> Enum.count() == 0
    end

    test "swipe_dismiss stamps data-swipe-dismiss and nothing else" do
      doc = render_opted(%{swipe_dismiss: true})

      assert LazyHTML.attribute(LazyHTML.query(doc, "#opt-sheet"), "data-swipe-dismiss") == [
               "true"
             ]

      assert doc |> LazyHTML.query("header .sheet-close-button") |> Enum.count() == 1
      assert doc |> LazyHTML.query("button.sheet-handle-button") |> Enum.count() == 0
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
