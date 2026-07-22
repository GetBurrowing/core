defmodule PlatformWeb.LayoutsExternalTest do
  @moduledoc """
  Unit coverage for the INERT external-chat app layout
  `PlatformWeb.Layouts.external/1` (rbac-external-users M4 stage 1, task
  019f8837).

  This is a pure function component — nothing renders it in any currently
  reachable environment (the `chat.` host that selects it is wired dark in
  stage 2 and no environment declares that host until M14). These asserts
  pin the two properties M5/M6/M7 depend on:

    * it renders its `@inner_content` inside the minimal `<main>` wrapper
      (so the external ChatLive branch has a mount point), and
    * it carries NONE of the shell chrome (icon-rail / bottom-rail /
      shell layout markers) — the whole point of a shell-less external
      surface.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  test "renders inner_content inside a shell-less <main> wrapper" do
    html =
      %{inner_content: {:safe, "SENTINEL"}, flash: %{}}
      |> PlatformWeb.Layouts.external()
      |> rendered_to_string()

    # Inner content is projected verbatim into the wrapper.
    assert html =~ "SENTINEL"

    # The definite-viewport-height <main> wrapper (matches guest/1, NOT
    # min-h-dvh) is present.
    assert html =~ ~s(<main)
    assert html =~ ~s(class="h-dvh bg-base-100 text-base-content")
    refute html =~ ~s(min-h-dvh)
  end

  test "carries no shell chrome (icon-rail / bottom-rail / shell markers)" do
    html =
      %{inner_content: {:safe, "SENTINEL"}, flash: %{}}
      |> PlatformWeb.Layouts.external()
      |> rendered_to_string()

    # None of the auth-shell chrome the `:shell` layout injects.
    refute html =~ "icon_rail"
    refute html =~ "icon-rail"
    refute html =~ "bottom_rail"
    refute html =~ "bottom-rail"
    refute html =~ "data-rail"
    refute html =~ ~s(id="app-shell")
  end

  test "tolerates a missing :flash assign (falls back to empty flash group)" do
    html =
      %{inner_content: {:safe, "SENTINEL"}}
      |> PlatformWeb.Layouts.external()
      |> rendered_to_string()

    assert html =~ "SENTINEL"
    # flash_group still renders its container off the `|| %{}` fallback.
    assert html =~ ~s(id="flash-group")
  end
end
