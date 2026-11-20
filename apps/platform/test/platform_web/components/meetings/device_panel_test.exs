defmodule PlatformWeb.Components.Meetings.DevicePanelTest do
  @moduledoc """
  The "Sound and video" panel (task 01a1f4c5 stage 2) and how
  `CallShell.call_controls/1` mounts it.

  What the server owns is the FRAME and the triggers; the rows are the
  `MeetingDevicePanel` hook's (device ids never reach the server), and the
  hook is covered by `assets/test/hooks/meeting_device_panel.test.js`.

  The load-bearing cases:

    * the existing toggles keep their `data-role`, `phx-click` and labels
      when the carets arrive (shipped tests and the quickmeet's container
      query depend on them);
    * nothing renders in native mode, where the native call owns audio;
    * no `.call-control-label` is added, because the quickmeet pins exactly
      four.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PlatformWeb.Components.Meetings.CallShell
  alias PlatformWeb.Components.Meetings.DevicePanel

  defp q(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp count(html, selector), do: html |> q(selector) |> Enum.count()
  defp attr(html, selector, name), do: html |> q(selector) |> LazyHTML.attribute(name)

  defp controls(overrides \\ []) do
    render_component(
      &CallShell.call_controls/1,
      Keyword.merge(
        [
          mic_event: "zzz_fake_mic",
          camera_event: "zzz_fake_camera",
          share_event: "zzz_fake_share",
          leave_event: "zzz_fake_leave",
          mic_role: "meeting-mic",
          camera_role: "meeting-camera"
        ],
        overrides
      )
    )
  end

  describe "device_panel/1" do
    test "the popover frame: title, the three section labels, empty ignored lists" do
      html = render_component(&DevicePanel.device_panel/1, id: "p", container: :popover)

      assert attr(html, "#p", "data-container") == ["popover"]
      assert attr(html, "#p", "role") == ["dialog"]
      assert attr(html, "#p", "hidden") == [""]
      assert html |> q("#p-title") |> LazyHTML.text() |> String.trim() == "Sound and video"

      labels = html |> q("h3") |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
      assert labels == ["Microphone", "Camera", "Speaker"]
      # Uppercase by CSS, base-content, never dimmed.
      for class <- attr(html, "h3", "class") do
        assert class =~ "uppercase"
        assert class =~ "text-base-content"
        assert class =~ "font-semibold"
        refute class =~ "text-subtle"
      end

      for kind <- DevicePanel.kinds() do
        list = "#p-#{kind}-list"
        assert attr(html, list, "phx-update") == ["ignore"]
        assert attr(html, list, "role") == ["radiogroup"]
        assert attr(html, list, "aria-labelledby") == ["p-#{kind}-label"]
        assert html |> q("#{list} > *") |> Enum.count() == 0
      end

      assert count(html, "[data-device-test-sound]") == 1
      assert count(html, ~s([data-device-section="audiooutput"] [data-device-test-sound])) == 1
      [test_sound] = attr(html, "[data-device-test-sound]", "class")
      assert test_sound =~ "btn-ghost"
      assert test_sound =~ "pointer-coarse:min-h-11"

      [panel_class] = attr(html, "#p", "class")

      for token <- ~w(bg-base-100 border-edge rounded-box shadow-lg text-base-content) do
        assert panel_class =~ token
      end
    end

    test "the sheet: scrim, rounded top, 75vh, clears the tab bar, a 44px close" do
      html = render_component(&DevicePanel.device_panel/1, id: "s", container: :sheet)

      assert attr(html, "#s", "aria-modal") == ["true"]
      [card] = attr(html, "#s [data-device-card]", "class")

      for token <-
            [
              "bg-base-100",
              "rounded-t-2xl",
              "max-h-[75vh]",
              "overflow-y-auto",
              "clears-tab-bar",
              "pb-[env(safe-area-inset-bottom)]"
            ] do
        assert card =~ token, "sheet card lacks #{token}"
      end

      [backdrop] = attr(html, "#s [data-device-backdrop]", "class")
      assert backdrop =~ "bg-scrim"
      assert attr(html, "#s [data-device-close]", "aria-label") == ["Close"]
      [close] = attr(html, "#s [data-device-close]", "class")
      assert close =~ "min-h-11" and close =~ "min-w-11"
    end

    test "sections is a subset, rendered in canonical order" do
      html =
        render_component(&DevicePanel.device_panel/1,
          id: "v",
          container: :popover,
          sections: ["audiooutput", "audioinput"]
        )

      assert attr(html, "[data-device-section]", "data-device-section") ==
               ["audioinput", "audiooutput"]

      assert count(html, ~s([data-device-section="videoinput"])) == 0
    end

    test "no colour literal or palette colour in the panel's markup" do
      for container <- [:popover, :sheet, :inline] do
        html = render_component(&DevicePanel.device_panel/1, id: "c", container: container)
        refute html =~ ~r/#[0-9a-fA-F]{3,8}\b/
        refute html =~ ~r/\b(bg|text|border)-(black|white|gray|slate|zinc|neutral-\d)/
        refute html =~ "text-primary"
        refute html =~ "btn-primary"
      end
    end
  end

  describe "lobby_devices/1 (task 01a1f4c5 stage 3)" do
    defp lobby, do: render_component(&DevicePanel.lobby_devices/1, %{})
    defp text(html, selector), do: html |> q(selector) |> LazyHTML.text() |> squish()
    defp squish(s), do: s |> String.split() |> Enum.join(" ")

    test "the heading, one row per kind in order, each with a Change link aimed at the lobby panel" do
      html = lobby()

      assert text(html, "#meeting-lobby-devices-title") == "You'll join with"

      assert attr(html, ~s([data-role="meeting-lobby-device-row"]), "data-kind") ==
               ~w(audioinput videoinput audiooutput)

      change = ~s([data-role="meeting-lobby-device-change"])
      assert count(html, change) == 3

      assert attr(html, change, "data-devices-for") ==
               List.duplicate("meeting-lobby-devices-panel", 3)

      assert attr(html, change, "data-devices-container") == ~w(auto auto auto)
      assert attr(html, change, "data-devices-section") == ~w(audioinput videoinput audiooutput)
      assert attr(html, change, "aria-expanded") == ~w(false false false)

      assert attr(html, change, "aria-label") ==
               ["Change microphone", "Change camera", "Change speaker"]

      for t <- html |> q(change) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim())) do
        assert t == "Change"
      end

      for class <- attr(html, change, "class") do
        assert class =~ "link"
        assert class =~ "text-base-content"
        assert class =~ "pointer-coarse:min-h-11"
      end

      # The icons the canvas names, one per row.
      for icon <- ~w(hero-microphone hero-video-camera hero-speaker-wave) do
        assert count(html, ~s([data-role="meeting-lobby-device-row"] .#{icon})) == 1
      end
    end

    test "only the microphone row has a meter, only the speaker row has Test sound" do
      html = lobby()

      assert count(html, ~s([data-lobby-device="audioinput"] [data-lobby-meter])) == 1
      assert count(html, "[data-lobby-meter]") == 1
      assert count(html, "[data-lobby-meter] [data-meter-bar].bg-info") == 5
      assert attr(html, "[data-lobby-meter]", "class") |> hd() =~ "bg-base-200"

      assert count(html, ~s([data-lobby-device="audiooutput"] [data-lobby-test-sound])) == 1
      assert count(html, "[data-lobby-test-sound]") == 1
      assert text(html, "[data-lobby-test-sound]") == "Test sound"
    end

    test "the mic check carries the canvas's three lines verbatim, hidden until the hook runs" do
      html = lobby()
      line = ~s([data-role="meeting-lobby-mic-check"])

      assert attr(html, line, "hidden") == [""]
      assert attr(html, line, "aria-live") == ["polite"]

      assert text(html, ~s(#{line} [data-mic-check-copy="invitation"])) ==
               "Say something to check your microphone."

      assert text(html, ~s(#{line} [data-mic-check-copy="heard"])) == "We can hear you"

      assert text(html, ~s(#{line} [data-mic-check-copy="warning"])) ==
               "No sound from this microphone. Try another?"

      # Heard: a check. Warning: a warning-coloured ICON, base-content text.
      assert attr(html, ~s([data-mic-check-icon="heard"]), "class") |> hd() =~ "hero-check"

      warning_icon = attr(html, ~s([data-mic-check-icon="warning"]), "class") |> hd()
      assert warning_icon =~ "hero-exclamation-triangle"
      assert warning_icon =~ "text-warning"
      assert attr(html, ~s([data-mic-check-icon="warning"]), "aria-hidden") == ["true"]
      assert attr(html, line, "class") |> hd() =~ "text-base-content"
      refute attr(html, line, "class") |> hd() =~ "text-warning"
    end

    test "the remembered-device lines, one per kind, hidden, in text-subtle" do
      html = lobby()
      sel = ~s([data-role="meeting-lobby-device-substituted"])

      assert attr(html, sel, "data-kind") == ~w(audioinput videoinput audiooutput)
      assert attr(html, sel, "hidden") == ["", "", ""]

      assert html |> q(sel) |> Enum.map(&(&1 |> LazyHTML.text() |> squish())) == [
               "Your usual microphone isn't connected.",
               "Your usual camera isn't connected.",
               "Your usual speaker isn't connected."
             ]

      for class <- attr(html, sel, "class"), do: assert(class =~ "text-subtle")
    end

    test "the rows sit in ONE ignored container; the panel hook holds an inline and a sheet panel" do
      html = lobby()

      assert attr(html, "#meeting-lobby-devices-rows", "phx-update") == ["ignore"]

      assert count(html, ~s(#meeting-lobby-devices-rows [data-role="meeting-lobby-device-row"])) ==
               3

      assert count(html, ~s(#meeting-lobby-devices-rows [data-role="meeting-lobby-mic-check"])) ==
               1

      assert attr(html, "#meeting-lobby-devices-panel", "phx-hook") == ["MeetingDevicePanel"]
      assert attr(html, "#meeting-lobby-devices-panel", "phx-update") == ["ignore"]

      assert attr(
               html,
               ~s(#meeting-lobby-devices-panel [data-role="meeting-device-panel"]),
               "data-container"
             ) ==
               ~w(inline sheet)

      # The inline accordion starts collapsed, with every section for the
      # hook to narrow to one.
      assert attr(html, "#meeting-lobby-devices-panel-inline", "hidden") == [""]

      assert attr(
               html,
               "#meeting-lobby-devices-panel-inline [data-device-section]",
               "data-device-section"
             ) ==
               ~w(audioinput videoinput audiooutput)

      assert count(html, "#meeting-lobby-devices-panel-sheet.fixed") == 1
    end

    test "no colour literal, no orange, no dimmed base-content in the block" do
      html = lobby()
      refute html =~ ~r/#[0-9a-fA-F]{3,8}\b/
      refute html =~ ~r/(?<![-\w])(text|bg|border|ring)-primary(?![-\w])/
      refute html =~ "btn-primary"
      refute html =~ ~r/text-base-content\/\d+/
    end
  end

  describe "call_controls/1 with devices_id" do
    test "desktop carets and the 44px phone trigger render, aimed at this bar's panel" do
      html = controls(devices_id: "devs")

      caret = ~s([data-role="call-control-mic-devices"])
      cam = ~s([data-role="call-control-camera-devices"])
      phone = ~s([data-role="call-control-devices"])

      for sel <- [caret, cam, phone] do
        assert count(html, sel) == 1
        assert attr(html, sel, "data-devices-for") == ["devs"]
        assert attr(html, sel, "aria-haspopup") == ["dialog"]
        assert attr(html, sel, "aria-expanded") == ["false"]
      end

      assert attr(html, caret, "aria-label") == ["Choose microphone"]
      assert attr(html, cam, "aria-label") == ["Choose camera"]
      assert attr(html, caret, "data-devices-section") == ["audioinput"]
      assert attr(html, cam, "data-devices-section") == ["videoinput"]
      assert attr(html, caret, "data-devices-container") == ["popover"]
      assert html |> q("#{caret} .hero-chevron-up") |> Enum.count() == 1

      # Carets: desktop with a fine pointer only. Phone trigger: the rest.
      [caret_class] = attr(html, caret, "class")
      assert "hidden" in String.split(caret_class)
      assert caret_class =~ "sm:pointer-fine:inline-flex"

      assert attr(html, phone, "aria-label") == ["Sound and video"]
      assert attr(html, phone, "data-devices-container") == ["sheet"]
      [phone_class] = attr(html, phone, "class")
      assert phone_class =~ "min-h-11" and phone_class =~ "min-w-11"
      assert phone_class =~ "sm:pointer-fine:hidden"

      # The hook root, its notice slot ABOVE the row, and both containers.
      assert attr(html, "#devs", "phx-hook") == ["MeetingDevicePanel"]
      assert attr(html, "#devs", "phx-update") == ["ignore"]
      assert attr(html, "#devs-notice", "aria-live") == ["polite"]
      assert attr(html, "#devs-notice", "role") == ["status"]
      assert count(html, "#devs-popover[data-container=popover]") == 1
      assert count(html, "#devs-sheet[data-container=sheet]") == 1

      # The panel is a SIBLING of the containment row, not inside it:
      # `container-type: inline-size` would trap the fixed sheet in the bar.
      assert count(html, ~s([data-component="call-controls"] [data-role="meeting-device-panel"])) ==
               0
    end

    test "the existing toggles keep data-role, phx-click and labels; no fifth label" do
      plain = controls()
      with_devices = controls(devices_id: "devs")

      for html <- [plain, with_devices] do
        assert attr(html, ~s([data-role="meeting-mic"]), "phx-click") == ["zzz_fake_mic"]
        assert attr(html, ~s([data-role="meeting-camera"]), "phx-click") == ["zzz_fake_camera"]
        assert attr(html, ~s([data-role="call-control-share"]), "phx-click") == ["zzz_fake_share"]
        assert attr(html, ~s([data-role="call-control-leave"]), "phx-click") == ["zzz_fake_leave"]
        assert attr(html, ~s([data-role="meeting-mic"]), "aria-label") == ["Mute microphone"]
        assert attr(html, ~s([data-role="meeting-camera"]), "aria-label") == ["Turn camera off"]
        assert count(html, ".call-control-label") == 4
      end

      # The mic toggle's title is the hook's (the new device name after a
      # fallback), so a LiveView patch must not strip it.
      [mounted] = attr(with_devices, ~s([data-role="meeting-mic"]), "phx-mounted")
      assert mounted =~ "ignore_attrs"
      assert mounted =~ "title"
      assert attr(with_devices, ~s([data-role="meeting-mic"]), "data-devices-toggle") == ["devs"]

      # Without devices_id nothing new renders.
      assert count(plain, "[data-devices-for]") == 0
      assert count(plain, ~s([data-role="meeting-devices"])) == 0
      assert attr(plain, ~s([data-role="meeting-mic"]), "phx-mounted") == []
    end

    test "nothing renders in native mode; the speaker button stays the output control" do
      html =
        controls(
          devices_id: "devs",
          speaker_id: "spk",
          native: %{mic: true, camera: true, active_speakers: []}
        )

      assert count(html, "[data-devices-for]") == 0
      assert count(html, ~s([data-role="meeting-devices"])) == 0
      assert count(html, ~s([data-role="meeting-device-panel"])) == 0
      assert count(html, "[data-devices-toggle]") == 0
      assert count(html, ~s([data-role="call-control-speaker"])) == 1
      assert count(html, ~s([data-role="meeting-mic"])) == 1
    end
  end
end
