defmodule PlatformWeb.Components.InputTest do
  @moduledoc """
  Unit tests for the `<.input>` component contract that the design-system
  input migration depends on (docs/design-system/components/input.md).

  Verifies: label/control association via `for`/`id`, the required-field
  asterisk (visible, aria-hidden), error rendering with `role="alert"`,
  and the `kind={:auto_resize}` textarea variant (`field-sizing: content`
  plus the on-scale min/max height classes).
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import PlatformWeb.CoreComponents

  defp render_input(assigns) do
    render_component(&input/1, assigns)
  end

  describe "label association" do
    test "pairs the label with the control via for/id" do
      html = render_input(id: "task-title", name: "task[title]", value: "", label: "Title")

      assert html =~ ~s(for="task-title")
      assert html =~ ~s(id="task-title")
    end

    test "renders no label span when label is absent" do
      html = render_input(id: "q", name: "q", value: "")

      refute html =~ ~s(class="label)
    end
  end

  describe "required asterisk" do
    test "renders an aria-hidden asterisk when required" do
      html = render_input(id: "t", name: "t", value: "", label: "Title", required: true)

      assert html =~ ~s(aria-hidden="true")
      assert html =~ ">*</span>"
      assert html =~ ~s(required)
    end

    test "renders no asterisk when not required" do
      html = render_input(id: "t", name: "t", value: "", label: "Title")

      refute html =~ ~s(aria-hidden="true")
    end
  end

  describe "errors" do
    test "renders error text with role=alert" do
      html =
        render_input(id: "t", name: "t", value: "", label: "Title", errors: ["can't be blank"])

      assert html =~ ~s(role="alert")
      assert html =~ "can&#39;t be blank"
    end
  end

  describe "kind={:auto_resize} textarea" do
    test "applies field-sizing plus the on-scale clamp classes" do
      html =
        render_input(
          id: "what",
          name: "task[what]",
          value: "hello",
          type: "textarea",
          kind: :auto_resize
        )

      assert html =~ ~s(style="field-sizing: content")
      assert html =~ "min-h-10"
      assert html =~ "max-h-50"
      assert html =~ "hello"
    end

    test "default textarea does not auto-resize" do
      html = render_input(id: "d", name: "d", value: "", type: "textarea")

      refute html =~ "field-sizing"
    end

    test "passes through phx-* and data-* attributes" do
      html =
        render_input(
          id: "w",
          name: "w",
          value: "",
          type: "textarea",
          kind: :auto_resize,
          "phx-keyup": "changed",
          "data-role": "my-textarea"
        )

      assert html =~ ~s(phx-keyup="changed")
      assert html =~ ~s(data-role="my-textarea")
    end
  end
end
