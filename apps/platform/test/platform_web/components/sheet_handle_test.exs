defmodule PlatformWeb.Components.SheetHandleTest do
  @moduledoc """
  FE-17 stage 1 — the bottom-sheet handle can carry a live deadline.

  On a phone the 30-second candidate window is only visible on the SHUT sheet,
  so the grab bar stops being purely decorative and becomes the countdown.
  This slice covers the component contract only:

    * no `:handle` slot -> the bar is still `aria-hidden="true"` and carries no
      `role="status"` (twelve existing call sites must not change);
    * a filled `:handle` slot -> the row carries the given accessible name and
      drops `aria-hidden`;
    * an existing call site (`<.more_sheet>`) renders the unchanged bar.

  Task: 01a07410 stage 1.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.Sheet

  defp render_bare do
    assigns = %{}

    rendered_to_string(~H"""
    <.sheet id="bare-sheet" open={true} placement={:bottom}>
      <:title>Bare</:title>
      <p>body</p>
    </.sheet>
    """)
  end

  defp render_with_handle do
    assigns = %{}

    rendered_to_string(~H"""
    <.sheet
      id="deadline-sheet"
      open={false}
      placement={:bottom}
      handle_label="30 seconds left to respond"
    >
      <:handle>
        <span class="sheet-handle__track" data-threshold="info">
          <span class="sheet-handle__fill" style="width: 100%"></span>
        </span>
        <span class="sheet-handle__numeral">30</span>
      </:handle>
      <:title>Deadline</:title>
      <p>body</p>
    </.sheet>
    """)
  end

  describe "handle with no :handle slot" do
    test "stays decorative: aria-hidden, no role=status, no accessible name" do
      html = render_bare()

      assert html =~ ~s(<div class="sheet-handle" aria-hidden="true"></div>)
      refute html =~ ~s(role="status")
      refute html =~ "sheet-handle--status"
    end
  end

  describe "handle WITH a :handle slot" do
    test "carries role=status and the given accessible name, and drops aria-hidden" do
      html = render_with_handle()

      assert html =~ ~s(role="status")
      assert html =~ ~s(aria-label="30 seconds left to respond")
      assert html =~ "sheet-handle__numeral"
      # The decorative bar is REPLACED, not merely supplemented: an aria-hidden
      # handle alongside a status handle would give the sheet two grab bars.
      refute html =~ ~s(<div class="sheet-handle" aria-hidden="true"></div>)
    end
  end

  describe "existing call sites are unchanged" do
    test "more_sheet still renders the plain aria-hidden grab bar" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <PlatformWeb.Components.MoreSheet.more_sheet
          open={true}
          is_fabrikam_user={false}
          current_user={nil}
        />
        """)

      assert html =~ ~s(<div class="sheet-handle" aria-hidden="true"></div>)
      refute html =~ ~s(role="status")
    end
  end
end
