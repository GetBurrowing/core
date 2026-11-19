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
