defmodule PlatformWeb.ChatLive.AttachMenuTest do
  @moduledoc """
  The composer's ＋ menu (redesign rung 11, task 01a1557a-9de3 stage 2): a
  bottom sheet on a phone and a popover on desktop, both driven by
  `:attach_menu_open`. Picks land in the stage-1 tray; a Recent canvases row
  stages the space's canvas, which posts as the message's `canvas_id` with
  the caption as ONE message. The server refuses another space's canvas.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  @app_root Path.expand("../../../..", __DIR__)
  @attach_path Path.join(@app_root, "lib/platform_web/live/chat/partials/attach.ex")

  defp login(conn) do
    user =
      Repo.insert!(%User{
        email: "attach_menu_#{System.unique_integer([:positive])}@example.com",
        name: "Attach Menu User",
        oidc_sub: "oidc-attach-menu-#{System.unique_integer([:positive])}"
      })

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp new_space(user, prefix) do
    slug = "#{prefix}-#{System.unique_integer([:positive])}"

    {:ok, space} =
      Chat.create_space(%{name: String.capitalize(slug), slug: slug, kind: "channel"})

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    {space, participant}
  end

  defp canvas(space, participant, title, ago_seconds) do
    {:ok, c} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "title" => title
      })

    at = DateTime.add(DateTime.utc_now(), -ago_seconds, :second)
    Repo.update_all(from(x in Chat.Canvas, where: x.id == ^c.id), set: [updated_at: at])
    %{c | updated_at: at}
  end

  defp open_menu(view), do: view |> element("#compose-attach-button") |> render_click()

  defp messages(space_id),
    do: Repo.all(from(m in Chat.Message, where: m.space_id == ^space_id))

  describe "the ＋ sheet and popover" do
    test "＋ opens a swipe-dismissable bottom sheet and the desktop popover", %{conn: conn} do
      {conn, user} = login(conn)
      {space, _p} = new_space(user, "attach-open")
      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      assert has_element?(
               view,
               ~s(#compose-attach-button[aria-label="Attach"][aria-haspopup="dialog"][aria-expanded="false"])
             )

      assert has_element?(view, ~s(#attach-sheet[data-open="false"]))
      refute has_element?(view, "#attach-popover")

      open_menu(view)

      assert has_element?(view, ~s(#compose-attach-button[aria-expanded="true"]))

      assert has_element?(
               view,
               ~s(#attach-sheet.sheet-bottom[data-open="true"][data-swipe-dismiss="true"])
             )

      assert has_element?(view, "#attach-sheet .sheet-handle-button")
      assert has_element?(view, ~s(#attach-sheet[data-on-close="attach_menu_close"]))
      assert has_element?(view, ~s(#attach-popover[role="dialog"]))

      html = view |> element("#attach-sheet") |> render()

      for copy <- [
            "Photos &amp; Videos",
            "View Library",
            "Camera",
            "Library",
            "Record an audio clip",
            "Record a video clip",
            "Upload a file",
            "Attach 0 items"
          ] do
        assert html =~ copy, "sheet is missing #{inspect(copy)}"
      end

      popover = view |> element("#attach-popover") |> render()

      for copy <- [
            "Attach",
            "Photos &amp; files from this computer",
            "or paste / drop into the composer",
            "Upload a file"
          ] do
        assert popover =~ copy, "popover is missing #{inspect(copy)}"
      end

      # No photo strip and no Attach button on desktop (direction rule 8).
      refute popover =~ "Attach 0 items"
      refute popover =~ "Camera"

      render_click(view, "attach_menu_close", %{})
      assert has_element?(view, ~s(#attach-sheet[data-open="false"]))
      refute has_element?(view, "#attach-popover")
    end

    test "with no canvases there is no Recent canvases label or row", %{conn: conn} do
      {conn, user} = login(conn)
      {space, _p} = new_space(user, "attach-nocanvas")
      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      open_menu(view)

      refute render(view) =~ "Recent canvases"
      refute has_element?(view, "[data-role=attach-canvas-row]")
    end

    test "3 canvases: the sheet lists the newest 2, the popover 3, each 'Edited …'", %{conn: conn} do
      {conn, user} = login(conn)
      {space, p} = new_space(user, "attach-canvases")
      canvas(space, p, "Mobile shell v3", 3 * 86_400)
      canvas(space, p, "Q4 launch plan", 2 * 3600)
      canvas(space, p, "Theme admin notes", 86_400)

      {other, op} = new_space(user, "attach-other")
      canvas(other, op, "Other space secret", 60)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      open_menu(view)

      sheet = view |> element("#attach-sheet") |> render()
      assert sheet =~ "Recent canvases"
      assert sheet =~ "Q4 launch plan"
      assert sheet =~ "Theme admin notes"
      refute sheet =~ "Mobile shell v3"
      assert sheet =~ "Edited 2h ago"
      assert sheet =~ "Edited 1d ago"

      popover = view |> element("#attach-popover") |> render()
      assert popover =~ "Mobile shell v3"
      assert popover =~ "Edited 3d ago"

      assert view |> element("#attach-sheet") |> render() |> count_rows() == 2
      assert view |> element("#attach-popover") |> render() |> count_rows() == 3

      # Another space's canvas is never offered.
      refute render(view) =~ "Other space secret"
    end

    test "attach_canvas stages a chip; Send posts ONE message with the caption and canvas_id",
         %{conn: conn} do
      {conn, user} = login(conn)
      {space, p} = new_space(user, "attach-send")
      plan = canvas(space, p, "Q4 launch plan", 2 * 3600)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      open_menu(view)

      view
      |> element(~s(#attach-sheet [data-role=attach-canvas-row][phx-value-id="#{plan.id}"]))
      |> render_click()

      assert has_element?(view, ~s(#attach-sheet[data-open="false"]))

      assert has_element?(
               view,
               ~s([data-role=staged-tray] [data-role=canvas-chip] button[aria-label="Remove Q4 launch plan"])
             )

      view |> form("#compose-form", compose: %{text: "the plan"}) |> render_submit()

      assert [message] = messages(space.id)
      assert message.content == "the plan"
      assert message.canvas_id == plan.id
      refute has_element?(view, "[data-role=staged-tray]")
    end

    test "a canvas from another space is refused, never staged or posted", %{conn: conn} do
      {conn, user} = login(conn)
      {space, _p} = new_space(user, "attach-forge")
      {other, op} = new_space(user, "attach-forge-other")
      foreign = canvas(other, op, "Other space secret", 60)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      render_click(view, "attach_canvas", %{"id" => foreign.id})

      refute has_element?(view, "[data-role=canvas-chip]")
      assert :sys.get_state(view.pid).socket.assigns.attach_canvas_id == nil

      view |> form("#compose-form", compose: %{text: "no canvas here"}) |> render_submit()
      assert [message] = messages(space.id)
      assert message.canvas_id == nil
    end

    test "a forged staged id is dropped at send time", %{conn: conn} do
      {conn, user} = login(conn)
      {space, _p} = new_space(user, "attach-forge-send")
      {other, op} = new_space(user, "attach-forge-send-other")
      foreign = canvas(other, op, "Other space secret", 60)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      # Bypass the picker entirely: plant the foreign id in the assign.
      :sys.replace_state(view.pid, fn state ->
        put_in(state.socket.assigns.attach_canvas_id, foreign.id)
      end)

      render_submit(view, "send_message", %{"compose" => %{"text" => "forged"}})
      assert [message] = messages(space.id)
      assert message.canvas_id == nil
    end

    test "a second canvas replaces the first", %{conn: conn} do
      {conn, user} = login(conn)
      {space, p} = new_space(user, "attach-replace")
      a = canvas(space, p, "First canvas", 60)
      b = canvas(space, p, "Second canvas", 120)

      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      render_click(view, "attach_canvas", %{"id" => a.id})
      render_click(view, "attach_canvas", %{"id" => b.id})

      assert has_element?(
               view,
               ~s([data-role=canvas-chip] button[aria-label="Remove Second canvas"])
             )

      refute has_element?(
               view,
               ~s([data-role=canvas-chip] button[aria-label="Remove First canvas"])
             )

      render_click(view, "attach_canvas_remove", %{})
      refute has_element?(view, "[data-role=canvas-chip]")
    end

    test "no link in the sheet or popover carries phx-click", %{conn: conn} do
      {conn, user} = login(conn)
      {space, p} = new_space(user, "attach-links")
      canvas(space, p, "Q4 launch plan", 60)
      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      open_menu(view)

      for root <- ["#attach-sheet", "#attach-popover"] do
        doc = view |> element(root) |> render() |> LazyHTML.from_fragment()
        buttons = doc |> LazyHTML.query("button") |> Enum.count()
        assert buttons > 0, "positive control: #{root} has buttons"
        assert doc |> LazyHTML.query("[data-phx-link][phx-click]") |> Enum.count() == 0
        assert doc |> LazyHTML.query("a[phx-click]") |> Enum.count() == 0
      end
    end
  end

  describe "the desktop drop target" do
    test "renders inside #chat-drop-zone, hidden below lg, with the masters' copy",
         %{conn: conn} do
      {conn, user} = login(conn)
      {space, _p} = new_space(user, "attach-drop")
      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      assert has_element?(view, ~s(#chat-drop-zone > #chat-drop-target[phx-update="ignore"]))

      target = "#chat-drop-target [data-role=drop-target]"
      assert has_element?(view, ~s(#{target}.hidden[aria-hidden="true"]))
      refute has_element?(view, ~s(#{target}.lg\\:flex))
      assert has_element?(view, "#{target} p.font-semibold.text-base-content", "Drop to attach")
      assert has_element?(view, "#{target} p.text-subtle", "lands in the composer, no panel")
      assert has_element?(view, "#{target} .border-dashed.border-edge.bg-base-200")
    end

    test "the add-more tile shows with a non-empty tray, desktop only", %{conn: conn} do
      {conn, user} = login(conn)
      {space, _p} = new_space(user, "attach-addmore")
      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")

      refute has_element?(view, "[data-role=attach-add-more]")

      view
      |> file_input("#compose-form", :attachments, [
        %{name: "a.png", content: String.duplicate("p", 100), type: "image/png"}
      ])
      |> render_upload("a.png")

      assert has_element?(
               view,
               ~s(li.max-lg\\:hidden button[data-role=attach-add-more][aria-label="Add another"][data-attach-pick="file"])
             )
    end
  end

  describe "palette scan of attach.ex" do
    test "no phone hover and no base-content opacity text" do
      src = File.read!(@attach_path)
      classes = Regex.scan(~r/class="([^"]*)"/, src) |> Enum.map(&List.last/1)
      assert length(classes) > 10, "positive control: the scan reads class strings"

      tokens = classes |> Enum.flat_map(&String.split/1)

      bare_hover =
        Enum.filter(
          tokens,
          &(String.contains?(&1, "hover:") and not String.starts_with?(&1, "lg:hover:"))
        )

      assert bare_hover == []
      assert Enum.filter(tokens, &String.starts_with?(&1, "text-base-content/")) == []
    end

    test "selection badges are never primary" do
      js = File.read!(Path.join(@app_root, "assets/js/hooks/attach_sheet.js"))
      [badge_on] = Regex.run(~r/const BADGE_ON =\s*"([^"]+)"/, js, capture: :all_but_first)
      assert badge_on =~ "bg-base-content"
      assert badge_on =~ "text-base-100"
      refute badge_on =~ "primary"
    end
  end

  defp count_rows(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role=attach-canvas-row]")
    |> Enum.count()
  end
end
