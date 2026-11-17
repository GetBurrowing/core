defmodule PlatformWeb.MeetingBarLiveTest do
  @moduledoc """
  The in-call top bar (task 01a1e82a stage 1, direction A of prototype
  01a1e823). Renders the LiveComponent directly and reads the markup with
  LazyHTML; the shell-level placement and per-page visibility live in
  `PlatformWeb.ShellLiveTest`.
  """
  use PlatformWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias PlatformWeb.MeetingBarLive

  @meeting_assigns %{
    meeting_active: true,
    meeting_space_id: "space-123",
    meeting_space_name: "Weekly sync",
    meeting_space_slug: "weekly-sync",
    meeting_slug: "weekly-sync-2026-11-17",
    meeting_started_at: ~U[2026-04-14 08:00:00Z],
    in_call_room: false,
    meeting_roster: [
      %{id: "p1", name: "Riley Park", initials: "RP"},
      %{id: "p2", name: "Sam", initials: "S"}
    ],
    meeting_here_count: 2,
    id: "meeting-bar"
  }

  defp doc(assigns),
    do: assigns |> then(&render_component(MeetingBarLive, &1)) |> LazyHTML.from_fragment()

  defp q(doc, selector), do: LazyHTML.query(doc, selector)
  defp present?(doc, selector), do: Enum.count(q(doc, selector)) > 0
  defp text(doc, selector), do: doc |> q(selector) |> LazyHTML.text() |> String.trim()

  defp attr(doc, selector, name) do
    case doc |> q(selector) |> LazyHTML.attribute(name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp classes(doc, selector), do: (attr(doc, selector, "class") || "") |> String.split()

  describe "visibility" do
    test "renders the bar when a meeting is active outside the call room" do
      assert present?(doc(@meeting_assigns), "#meeting-top-bar")
    end

    test "renders nothing in the call room" do
      d = doc(Map.put(@meeting_assigns, :in_call_room, true))

      refute present?(d, "#meeting-top-bar")
      refute present?(d, "[data-bar-mic]")
    end

    test "renders nothing with no active meeting" do
      refute present?(doc(Map.put(@meeting_assigns, :meeting_active, false)), "#meeting-top-bar")
    end
  end

  describe "direction-A markup" do
    test "carries the prototype copy in order on desktop" do
      d = doc(@meeting_assigns)
      bar = text(d, "#meeting-top-bar") |> String.replace(~r/\s+/, " ")

      # The reconnecting / lost spans and Rejoin are in the markup but hidden
      # while connected (stage 2); see "reconnecting and lost" below.
      assert bar =~
               ~r/In call Weekly sync 0:00 (Reconnecting… 0:00 Connection lost )?RP S 2 here .*Mic on Cam off Return to call ↗ (Rejoin Leave )?Leave/

      assert text(d, "[data-role=meeting-name]") == "Weekly sync"
      assert text(d, "[data-role=meeting-here]") == "2 here"
      assert text(d, "[data-role=meeting-return]") == "Return to call ↗"
      assert text(d, "[data-bar-leave]") == "Leave"
    end

    test "paints the band in success tokens with warning variants for reconnecting" do
      cls = classes(doc(@meeting_assigns), "#meeting-top-bar")

      assert "bg-success" in cls
      assert "text-success-content" in cls
      assert "data-[state=reconnecting]:bg-warning" in cls
      assert "data-[state=reconnecting]:text-warning-content" in cls
      assert "sm:h-11" in cls
    end

    test "is in flow at the top, not the old fixed bottom ribbon" do
      d = doc(@meeting_assigns)
      cls = classes(d, "#meeting-top-bar")

      refute "fixed" in cls
      refute "bg-base-100" in cls
      refute Enum.any?(cls, &String.starts_with?(&1, "bottom-"))
      refute present?(d, "#meeting-mini-bar")
    end

    test "starts connected and protects data-state from server patches" do
      d = doc(@meeting_assigns)

      assert attr(d, "#meeting-top-bar", "data-state") == "connected"
      assert attr(d, "#meeting-top-bar", "phx-mounted") =~ "ignore_attrs"
      assert attr(d, "#meeting-top-bar", "phx-mounted") =~ "data-state"
      assert attr(d, "#meeting-top-bar", "phx-mounted") =~ "data-lost"
    end

    # Task 01a1e82a stage 2: meeting_presence.js sets data-state=reconnecting
    # (and data-lost=true after 30s); these variants and slots are what it
    # repaints. The old body-level banner is folded into the bar.
    test "reconnecting and lost: the clock gives way, Rejoin and the phone Leave sheet appear" do
      d = doc(@meeting_assigns)

      assert attr(d, "#meeting-top-bar [data-timer]", "class") =~
               "group-data-[state=reconnecting]:hidden"

      status = "#meeting-top-bar [data-role=meeting-conn-status]"
      assert attr(d, status, "class") =~ "group-data-[state=reconnecting]:inline"
      assert text(d, status) |> String.replace(~r/\s+/, " ") =~ "Reconnecting… 0:00"
      assert text(d, status) =~ "Connection lost"
      assert present?(d, "#{status} [data-conn-timer]")

      assert text(d, "#meeting-top-bar [data-bar-rejoin]") == "Rejoin"
      assert text(d, "#meeting-top-bar [data-meeting-leave-sheet]") == "Leave"
      assert attr(d, "#meeting-top-bar", "class") =~ "data-[state=reconnecting]:bg-warning"
    end

    test "keeps the MeetingBar hook, timer and started-at contract" do
      d = doc(@meeting_assigns)

      assert attr(d, "#meeting-top-bar", "phx-hook") == "MeetingBar"
      assert attr(d, "#meeting-top-bar", "data-started-at") == "2026-04-14T08:00:00Z"
      assert Enum.count(q(d, "#meeting-top-bar [data-timer]")) == 1
    end

    test "shows up to the roster's faces, and no faces or count with an empty roster" do
      d = doc(@meeting_assigns)
      assert Enum.count(q(d, "[data-role=meeting-faces] > span")) == 2

      empty = doc(%{@meeting_assigns | meeting_roster: [], meeting_here_count: 0})
      refute present?(empty, "[data-role=meeting-faces]")
      refute present?(empty, "[data-role=meeting-here]")
    end

    test "Leave is in error tokens" do
      cls = classes(doc(@meeting_assigns), "[data-bar-leave]")

      assert "bg-error" in cls
      assert "text-error-content" in cls
    end

    test "the phone strip is the whole bar as a link to the call" do
      d = doc(@meeting_assigns)

      assert text(d, "#meeting-top-bar") =~ "Tap to return ›"

      assert attr(d, "[data-role=meeting-strip-link]", "href") ==
               "/meetings/weekly-sync-2026-11-17"

      assert "absolute" in classes(d, "[data-role=meeting-strip-link]")
      assert "sm:hidden" in classes(d, "[data-role=meeting-strip-link]")
      # The desktop controls are hidden below sm.
      assert "hidden" in classes(d, "[data-bar-mic]")
      assert "sm:inline-flex" in classes(d, "[data-bar-mic]")
    end
  end

  describe "return to call" do
    test "deep-links to /meetings/<meeting_slug>" do
      assert attr(doc(@meeting_assigns), "[data-role=meeting-return]", "href") ==
               "/meetings/weekly-sync-2026-11-17"
    end

    test "falls back to /chat/<space_slug> when meeting_slug is nil" do
      d = doc(Map.put(@meeting_assigns, :meeting_slug, nil))
      assert attr(d, "[data-role=meeting-return]", "href") == "/chat/weekly-sync"
    end

    test "falls back to /chat/<space_id> when both slugs are nil" do
      d = doc(%{@meeting_assigns | meeting_slug: nil, meeting_space_slug: nil})
      assert attr(d, "[data-role=meeting-return]", "href") == "/chat/space-123"
    end
  end

  describe "controls" do
    test "include the data-bar attributes the MeetingBar hook binds" do
      d = doc(@meeting_assigns)

      assert present?(d, "[data-bar-mic]")
      assert present?(d, "[data-bar-camera]")
      assert present?(d, "[data-bar-leave]")
    end

    # Stage 4 (task 019ee06b): the MeetingBar JS hook is the sole click
    # handler for the media toggles; Leave keeps its server path.
    test "mic and camera have no phx-click, Leave does" do
      d = doc(@meeting_assigns)

      assert attr(d, "[data-bar-mic]", "phx-click") == nil
      assert attr(d, "[data-bar-camera]", "phx-click") == nil
      assert attr(d, "[data-bar-leave]", "phx-click") == "leave_meeting"
    end

    test "defaults to Mic on (soft well) and Cam off (inverted chip)" do
      d = doc(@meeting_assigns)

      assert text(d, "[data-bar-mic]") == "Mic on"
      assert "bg-success-content/15" in classes(d, "[data-bar-mic]")
      assert attr(d, "[data-bar-mic]", "title") == "Mute mic"

      assert text(d, "[data-bar-camera]") == "Cam off"
      assert "bg-success-content" in classes(d, "[data-bar-camera]")
      assert "text-success" in classes(d, "[data-bar-camera]")
      assert "group-data-[state=reconnecting]:text-warning" in classes(d, "[data-bar-camera]")
    end

    # Task 01a13c62 stage 3: inside the iOS app the bar follows the native call.
    test "native mode hides the camera and renders a pending mic disabled" do
      d =
        doc(
          Map.merge(@meeting_assigns, %{
            native: %{mic: true, camera: false, active_speakers: true},
            mic_pending: true
          })
        )

      refute present?(d, "[data-bar-camera]")
      assert present?(d, "[data-bar-mic][disabled]")
      assert attr(d, "[data-bar-mic]", "aria-busy") == "true"
      assert "ring-warning" in classes(d, "[data-bar-mic]")
    end

    test "in a browser the bar keeps mic and camera without the pending ring" do
      d = doc(@meeting_assigns)

      assert present?(d, "[data-bar-camera]")
      refute "ring-warning" in classes(d, "[data-bar-mic]")
    end
  end

  # Stage 3 (task 019ee06b): mic/camera arrive from ShellLive via
  # `send_update/2`; an explicit `false` must win over the default.
  describe "media state override" do
    test "mic_on=false renders Mic off as the inverted chip" do
      d = doc(Map.put(@meeting_assigns, :mic_on, false))

      assert text(d, "[data-bar-mic]") == "Mic off"
      assert attr(d, "[data-bar-mic]", "title") == "Unmute mic"
      assert "text-success" in classes(d, "[data-bar-mic]")
    end

    test "camera_on=true renders Cam on as a soft well" do
      d = doc(Map.put(@meeting_assigns, :camera_on, true))

      assert text(d, "[data-bar-camera]") == "Cam on"
      refute "text-success" in classes(d, "[data-bar-camera]")
    end
  end
end
