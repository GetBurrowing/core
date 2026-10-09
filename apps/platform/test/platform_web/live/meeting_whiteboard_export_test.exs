defmodule PlatformWeb.MeetingWhiteboardExportTest do
  @moduledoc """
  Exporting the meeting whiteboard into a Suite canvas (task 019fcfcf stage 5).

  Its own file, and `async: false`, deliberately. The write path goes through
  `Platform.Chat.Canvas.Server`, a lazily-started GenServer that is neither the
  sandbox owner nor an allowed process under `async: true` — every canvas
  assertion there dies with `DBConnection.OwnershipError` before it can say
  anything about the feature. Shared-mode sandbox is what lets the canvas
  server touch the same connection the test does.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.{Chat, Repo}
  alias Platform.Accounts.User
  alias Platform.Chat.Attachment
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Meetings.Meeting
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "wb_export_#{System.unique_integer([:positive])}@example.com",
        name: "Whiteboard Export User",
        oidc_sub: "oidc-wb-export-#{System.unique_integer([:positive])}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp create_meeting(attrs) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Meeting Space #{System.unique_integer([:positive])}",
        slug: "meeting-space-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Meeting Project #{System.unique_integer([:positive])}",
        slug: "meeting-project-#{System.unique_integer([:positive])}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: Map.fetch!(attrs, :slug),
        name: Map.fetch!(attrs, :name),
        livekit_room_name: "meeting-#{meeting_id}"
      })
      |> Repo.insert()

    {meeting, space}
  end

  defp wb_join!(space, user, name) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  # Just the opening tag of the ignored host, so "the re-render did not touch
  # it" is an assertion about the exact bytes LiveView stamped.
  defp host_element(html) do
    case Regex.run(~r/<div[^>]*id="meeting-whiteboard-host"[^>]*>/, html) do
      [tag] -> tag
      nil -> flunk("no #meeting-whiteboard-host element in the rendered page")
    end
  end

  describe "whiteboard export to canvas (task 019fcfcf stage 5)" do
    setup %{conn: conn} do
      {meeting, space} =
        create_meeting(%{slug: "whiteboard-export", name: "Whiteboard Export"})

      {conn, user} = authenticated_conn(conn)
      {:ok, conn: conn, meeting: meeting, space: space, user: user}
    end

    defp space_attachments(space_id) do
      Attachment
      |> Platform.Repo.all()
      |> Enum.filter(&(&1.space_id == space_id))
    end

    # Drive the whole three-legged chain and return the appended card's
    # children keyed by type, plus the canvas.
    defp export_board!(view, space_id) do
      render_hook(view, "whiteboard_export", %{
        "png_byte_size" => 4096,
        "json_byte_size" => 512
      })

      assert_push_event(view, "whiteboard_export_reserved", %{
        png: %{id: png_id},
        json: %{id: json_id}
      })

      render_hook(view, "whiteboard_export_uploaded", %{
        "png_attachment_id" => png_id,
        "json_attachment_id" => json_id
      })

      canvas = List.last(Chat.list_canvases(space_id))
      {:ok, %{document: doc}} = CanvasServer.describe(canvas.id)
      {canvas, doc, png_id, json_id}
    end

    defp card_children(doc) do
      cards =
        doc["root"]["children"]
        |> Enum.filter(&(&1["type"] == "card"))

      {cards, Enum.flat_map(cards, & &1["children"])}
    end

    test "a non-participant's export reserves no attachment and writes no canvas", %{
      conn: conn,
      meeting: meeting,
      space: space,
      user: user
    } do
      # `?no_autojoin=true` for the same reason as the save test: a plain
      # mount auto-joins and there would be no non-participant to test.
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}?no_autojoin=true")

      refute Enum.any?(Chat.list_participants(space.id), fn p ->
               p.participant_type == "user" and p.participant_id == user.id
             end)

      # Both the authorisation gate and the reservation step refuse.
      render_click(view, "whiteboard_export_start", %{})
      refute_push_event(view, "whiteboard_export_begin", %{})

      render_hook(view, "whiteboard_export", %{
        "png_byte_size" => 4096,
        "json_byte_size" => 512
      })

      # Reservation first, because it is the specific claim: nothing was
      # written, no signed URL was minted. Defence in depth — with the
      # handler's own participant check removed this still holds, because
      # `upload_start` re-checks membership at the seam. Verified by mutating
      # BOTH (handler guard deleted AND `require_user_member` forced to `:ok`),
      # at which point this line is the one that fires.
      assert space_attachments(space.id) == []
      refute_push_event(view, "whiteboard_export_reserved", %{})
      assert Chat.list_canvases(space.id) == []
      assert render(view) =~ "Join the meeting to send the whiteboard to a canvas"

      # Positive control in the same run, or this test passes for a handler
      # that refuses everyone.
      wb_join!(space, user, "Exporter")
      {:ok, member_view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      render_click(member_view, "whiteboard_export_start", %{})
      assert_push_event(member_view, "whiteboard_export_begin", %{})

      render_hook(member_view, "whiteboard_export", %{
        "png_byte_size" => 4096,
        "json_byte_size" => 512
      })

      assert_push_event(member_view, "whiteboard_export_reserved", %{})

      # TWO artefacts, not one: the PNG renders, the scene JSON is what makes
      # the board reopenable. A change that ships only the PNG fails here.
      types = space.id |> space_attachments() |> Enum.map(& &1.content_type) |> Enum.sort()
      assert types == ["application/json", "image/png"]
    end

    test "a successful export appends exactly one card carrying both artefacts", %{
      conn: conn,
      meeting: meeting,
      space: space,
      user: user
    } do
      wb_join!(space, user, "Exporter")
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      {canvas, doc, png_id, json_id} = export_board!(view, space.id)

      {cards, children} = card_children(doc)
      assert length(cards) == 1

      image = Enum.find(children, &(&1["type"] == "image"))
      assert image, "the appended card has no image node"

      # The hard constraint. `Kinds.Image` enforces this server-side; the
      # src must be the URL `upload_start` returned, verbatim.
      assert image["props"]["src"] =~
               ~r|^/chat/attachments/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$|

      assert image["props"]["src"] == "/chat/attachments/#{png_id}"

      # The scene file is linked, so the board is reopenable — not just a
      # picture of a whiteboard.
      markdown = Enum.find(children, &(&1["type"] == "markdown"))
      assert markdown["props"]["content"] =~ "/chat/attachments/#{json_id}"
      # Two distinct attachments, not the PNG linked twice.
      refute json_id == png_id

      heading = Enum.find(children, &(&1["type"] == "heading"))
      assert heading["props"]["value"] == "#{meeting.name} whiteboard"

      # The write was ACCEPTED, not merely non-crashing: the canvas the
      # server refetched is the meeting's, and it now holds the card.
      assert canvas.space_id == space.id

      # Exporting twice appends a second card rather than replacing the first.
      {_canvas, doc2, _p, _j} = export_board!(view, space.id)
      {cards2, _} = card_children(doc2)
      assert length(cards2) == 2
    end

    # The negative case the guard exists for. Verified to FAIL when the
    # `Regex.match?` in `Platform.Chat.Canvas.Kinds.Image.validate_props/1`
    # is replaced with `true`: patch_canvas then ACCEPTS the external URL and
    # both assertions below fire. A guard that has only ever passed a
    # well-formed input proves nothing.
    test "a malformed image src is rejected by the canvas write itself", %{
      conn: conn,
      meeting: meeting,
      space: space,
      user: user
    } do
      wb_join!(space, user, "Exporter")
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      {canvas, doc, _png_id, _json_id} = export_board!(view, space.id)
      {cards_before, _} = card_children(doc)

      bad_card = %{
        "id" => "whiteboard-export-bad",
        "type" => "card",
        "children" => [
          %{
            "id" => "whiteboard-export-bad-image",
            "type" => "image",
            "props" => %{"src" => "https://example.test/board.png"}
          }
        ]
      }

      assert {:conflict, %{reason: :schema_violation, message: message}} =
               Chat.patch_canvas({:user, user.id}, canvas, [
                 {:append_child, "root", bad_card}
               ])

      # Named, not just "some error" — the rejection must come from the image
      # src guard and not from an unrelated schema complaint that would make
      # this test pass for the wrong reason.
      assert message =~ "image src must be a path-relative /chat/attachments/<uuid> URL"
      assert message =~ "https://example.test/board.png"

      {:ok, %{document: after_doc}} = CanvasServer.describe(canvas.id)
      {cards_after, _} = card_children(after_doc)
      assert length(cards_after) == length(cards_before)
    end

    test "an id the server did not reserve writes nothing", %{
      conn: conn,
      meeting: meeting,
      space: space,
      user: user
    } do
      wb_join!(space, user, "Exporter")
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")

      render_hook(view, "whiteboard_export", %{
        "png_byte_size" => 4096,
        "json_byte_size" => 512
      })

      assert_push_event(view, "whiteboard_export_reserved", %{json: %{id: json_id}})

      # A crafted id — the src of a canvas image is server-held, so the
      # echoed ids must be exactly the ones this socket reserved.
      render_hook(view, "whiteboard_export_uploaded", %{
        "png_attachment_id" => Ecto.UUID.generate(),
        "json_attachment_id" => json_id
      })

      assert Chat.list_canvases(space.id) == []
    end

    test "the export control is a sibling of the ignored host, not a child", %{
      conn: conn,
      meeting: meeting
    } do
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      html = render_click(view, "set_stage_mode", %{"mode" => "whiteboard"})

      assert html =~ ~s(data-action="whiteboard-export")

      [inner] =
        Regex.run(
          ~r/<div[^>]*id="meeting-whiteboard-host"[^>]*>(.*?)<\/div>/s,
          html,
          capture: :all_but_first
        )

      assert String.trim(inner) == ""
    end

    # The stage-3/4 invariant, restated for the control that is new here:
    # clicking "Send to canvas" IS a LiveView re-render, and per #664/#665
    # that re-render must leave the hook-owned host untouched.
    test "clicking the export control leaves the ignored host untouched", %{
      conn: conn,
      meeting: meeting,
      space: space,
      user: user
    } do
      wb_join!(space, user, "Exporter")
      {:ok, view, _html} = live(conn, ~p"/meetings/#{meeting.slug}")
      before_html = render_click(view, "set_stage_mode", %{"mode" => "whiteboard"})

      after_html =
        view
        |> element(~s([data-action="whiteboard-export"]))
        |> render_click()

      assert host_element(after_html) == host_element(before_html)
      refute host_element(after_html) =~ "data-active"
    end
  end
end
