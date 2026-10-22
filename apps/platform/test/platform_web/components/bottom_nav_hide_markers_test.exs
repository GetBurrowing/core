defmodule PlatformWeb.Components.BottomNavHideMarkersTest do
  @moduledoc """
  The markup half of the mobile tab bar's hide rules (task
  01a1557a-7a71-7000-8580-75565039bffe, Burrow redesign 4, stage 3).

  app.css hides the bar under exactly three selectors:

    * `:root:has([phx-hook="ComposeInput"]:focus)`: keyboard up with a
      composer focused (composer focus is the proxy for "keyboard up");
    * `:root:has([data-fullscreen-viewer])`: a full-screen viewer;
    * `:root:has([data-in-call])`: MeetingLive while in the call (pinned in
      meeting_live_test.exs, where the join lifecycle lives).

  A selector is only as good as the attribute it keys on. These tests pin
  that each viewer renders `data-fullscreen-viewer` exactly while it covers
  the viewport, and that every ComposeInput composer still carries the hook
  attribute the focus selector reads. The CSS half is
  `test/platform/design/bottom_nav_glass_guard_test.exs`.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias PlatformWeb.ChatLive.Partials

  @lib Path.expand("../../../lib/platform_web", __DIR__)

  describe "full-screen viewers carry data-fullscreen-viewer" do
    test "the image lightbox, while open, and not when closed" do
      assigns = %{url: "/chat/attachments/00000000-0000-0000-0000-000000000000"}
      open = rendered_to_string(~H"<Partials.image_lightbox url={@url} />")

      assert open
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("[data-fullscreen-viewer]")
             |> Enum.count() == 1

      assigns = %{url: nil}
      closed = rendered_to_string(~H"<Partials.image_lightbox url={@url} />")
      refute closed =~ "data-fullscreen-viewer"
    end

    test "the file preview's full-screen state and the full-screen prototype declare it" do
      # Both render deep inside LiveViews with heavy fixtures; their templates
      # are read instead, keyed on the element that covers the viewport.
      preview = File.read!(Path.join(@lib, "components/file_preview.ex"))
      [fullscreen] = Regex.run(~r/id="files-preview-fullscreen".*?>/s, preview)
      assert fullscreen =~ "data-fullscreen-viewer"

      proto = File.read!(Path.join(@lib, "components/canvases/prototype_frame.ex"))
      assert proto =~ ~s(data-fullscreen-viewer={@fullscreen && "true"})
    end
  end

  describe "every ComposeInput composer keeps the hook attribute the focus selector reads" do
    # Chat composer, inline thread reply, task steering.
    @call_sites [
      "live/chat/partials/composer.ex",
      "components/chat_message.ex",
      "live/tasks/steering_component.ex"
    ]

    test "the three known call sites, and no unlisted one" do
      found =
        Path.wildcard(Path.join(@lib, "**/*.{ex,heex}"))
        |> Enum.filter(&(File.read!(&1) =~ ~s(phx-hook="ComposeInput")))
        |> Enum.map(&Path.relative_to(&1, @lib))
        |> Enum.sort()

      assert found == Enum.sort(@call_sites),
             "the composer set changed; each field must carry " <>
               ~s(phx-hook="ComposeInput" or the tab bar stops hiding for it: #{inspect(found)})

      # The hook must sit on the focusable field itself: the chat and task
      # composers are <textarea>, the inline thread reply is <input
      # type="text">. The tag is the nearest `<tag` opener before the hook.
      for site <- @call_sites do
        src = File.read!(Path.join(@lib, site))
        # The last occurrence: steering_component's moduledoc names the hook first.
        {at, _} = src |> :binary.matches(~s(phx-hook="ComposeInput")) |> List.last()
        before = binary_part(src, 0, at)

        [[tag] | _] =
          ~r/<([a-z][a-z0-9.-]*)\b/
          |> Regex.scan(before, capture: :all_but_first)
          |> Enum.reverse()

        assert tag in ["textarea", "input"],
               "#{site}: phx-hook=\"ComposeInput\" sits on <#{tag}>, not on the field"
      end
    end
  end

  describe "scroll ends clear the floating bar (task 01a1557a-7a71 stage 5)" do
    # The scrollers the 34px-safe-area inventory found under the bar, each
    # identified by a fragment of its own opening tag. Each must carry
    # `clears-tab-bar` (app.css: padding-bottom 1rem + --bottom-nav-clearance).
    @scrollers [
      {"live/inbox_live.html.heex", ~s(data-role="inbox-surface")},
      {"live/inbox/inbox_list.ex", ~s(data-role="inbox-phone-list")},
      {"live/files_live.html.heex", ~s(data-role="file-dropzone")},
      {"live/meeting_live.html.heex", ~s(overflow-y-auto px-3 py-3 sm:px-6 sm:py-5)},
      {"live/admin_branding_live.html.heex", ~s(overflow-y-auto px-4 py-6)},
      {"live/admin_prompts_live.html.heex", ~s(data-role="declared-missing-pane")},
      {"live/admin_prompts_live.html.heex", ~s(flex-col overflow-y-auto p-4 gap-6)},
      {"live/recovery_live.html.heex", ~s(min-h-0 flex-1 overflow-y-auto p-4)},
      {"live/access_live.html.heex", ~s(id="access-panel")}
    ]

    test "each listed scroller's opening tag carries clears-tab-bar" do
      missing =
        for {file, marker} <- @scrollers,
            src = File.read!(Path.join(@lib, file)),
            tag = opening_tag!(src, marker, file),
            not String.contains?(tag, "clears-tab-bar"),
            do: {file, marker}

      assert missing == []
    end
  end

  defp opening_tag!(src, marker, file) do
    case :binary.match(src, marker) do
      {at, _} ->
        start = src |> binary_part(0, at) |> :binary.matches("<") |> List.last() |> elem(0)
        rest = binary_part(src, start, byte_size(src) - start)
        [tag | _] = String.split(rest, ">", parts: 2)
        tag

      :nomatch ->
        flunk("#{file}: no #{inspect(marker)}; the scroller moved, update this list")
    end
  end
end
