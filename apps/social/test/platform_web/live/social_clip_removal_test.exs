defmodule PlatformWeb.SocialClipRemovalTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  alias Platform.{Repo, Social}
  alias Platform.Social.{AgentDrafts, ClipVersions}

  setup do
    %{w: render_world!()}
  end

  defp clip!(w, title) do
    file = stored_file!(w.project, "render #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{file_id: file.id, title: title},
        w.agent.id
      )

    clip
  end

  defp open(conn, user, view \\ "review") do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, parent, _} = live(conn, "/m/social?tab=clips&view=#{view}")
    find_live_child(parent, "ext-page-social")
  end

  test "named confirmation cancels safely then deletes selected clip from a long queue", %{
    conn: conn,
    w: w
  } do
    clips = for n <- 1..35, do: clip!(w, "Clip #{n}")
    [first, second, third | _] = clips
    child = open(conn, w.approver)

    child
    |> element("[data-role=clips-queue-item][data-clip-id='#{second.id}']")
    |> render_click()

    child |> element("[data-role=clip-delete]") |> render_click()
    assert has_element?(child, "[role=dialog]", "Delete Clip 2?")
    assert has_element?(child, "[role=dialog]", "Media files remain under Files retention")
    child |> element("[data-role=clip-delete-cancel]") |> render_click()
    refute has_element?(child, "[data-role=clip-delete-dialog]")
    assert has_element?(child, "[data-role=clip-manage-menu][open]")
    assert Social.get_clip(w.org_id, second.id)
    child |> element("[data-role=clip-delete]") |> render_click()
    child |> element("[data-role=clip-delete-confirm]") |> render_click()
    refute has_element?(child, "[data-role=clips-queue-item][data-clip-id='#{second.id}']")
    assert has_element?(child, "[data-role=clips-bay][data-clip-id='#{third.id}']")
    assert has_element?(child, "[data-role=clips-queue-count]", "34")
    assert Social.get_clip(w.org_id, first.id)
    assert Social.get_clip(w.org_id, second.id) == nil
  end

  test "deleting the last render reaches the empty state rather than a broken player", %{
    conn: conn,
    w: w
  } do
    clip = clip!(w, "Last clip")
    child = open(conn, w.approver)
    child |> element("[data-role=render-delete]") |> render_click()
    assert has_element?(child, "[data-role=clip-delete-dialog]", "Delete Last clip v1?")
    child |> element("[data-role=clip-delete-confirm]") |> render_click()
    refute has_element?(child, "[data-role=clip-player]")
    refute has_element?(child, "[data-role=clip-approve]")
    assert has_element?(child, "[data-role=clips-queue-count]", "0")
    assert Social.get_clip(w.org_id, clip.id) == nil
  end

  test "render-row deletion promotes the precise remaining playable version", %{conn: conn, w: w} do
    clip = clip!(w, "Original")
    file = stored_file!(w.project, "new version #{unique()}", "new.mp4", "video/mp4")

    {:ok, promoted} =
      Repo.transaction(fn ->
        ClipVersions.append!(clip.id, file, %{title: "New"}, %{headline: "New"})
      end)

    selected = render_id!(promoted)
    child = open(conn, w.approver)

    child
    |> element(
      "[data-role=clip-render-row][data-render-id='#{selected}'] [data-role=render-delete]"
    )
    |> render_click()

    child |> element("[data-role=clip-delete-confirm]") |> render_click()
    refute has_element?(child, "[data-role=clip-render-row][data-render-id='#{selected}']")

    assert has_element?(
             child,
             "[data-role=clip-player] video[src='/files/blob/#{clip.render_file_id}']"
           )

    assert has_element?(
             child,
             "[data-role=clip-approve][phx-value-render_id='#{render_id!(clip)}']"
           )
  end

  test "a new render closes an older deletion confirmation", %{conn: conn, w: w} do
    clip = clip!(w, "Original")
    # Keep the Files browser and its canvas-presence subscriptions mounted too.
    participant = join!(w.profile.space_id, :user, w.approver.id)

    {:ok, canvas} =
      Platform.Chat.create_canvas(%{
        space_id: w.profile.space_id,
        created_by: participant.id,
        title: "Review context",
        document: %{
          "version" => 1,
          "revision" => 1,
          "root" => %{"id" => "root", "type" => "text", "props" => %{"value" => "Review context"}}
        }
      })

    files_conn = Plug.Test.init_test_session(conn, current_user_id: w.approver.id)
    {:ok, files, _} = live(files_conn, "/files?space=#{w.profile.space_id}&type=canvas")
    assert has_element?(files, "[data-kind=canvas][data-item-id='#{canvas.id}']")
    child = open(conn, w.approver)
    child |> element("[data-role=clip-delete]") |> render_click()
    assert has_element?(child, "[data-role=clip-delete-dialog]")

    file = stored_file!(w.project, "replacement #{unique()}", "new.mp4", "video/mp4")

    {:ok, updated} =
      Repo.transaction(fn ->
        ClipVersions.append!(clip.id, file, %{title: "Replacement"}, %{headline: "Replacement"})
      end)

    Social.broadcast_clip(updated)
    # The broadcast handler queues send_update to itself. Flush that first hop
    # before the assertion's ping observes the component's updated render.
    render(child)
    assert has_element?(child, "#clip-player-#{clip.id}-r2")
    refute has_element?(child, "[data-role=clip-delete-dialog]")
    assert Social.get_clip(w.org_id, clip.id).rev == 2
  end

  test "Library shares guards and removal, and refreshes after its deletion broadcast", %{
    conn: conn,
    w: w
  } do
    clip = clip!(w, "Library clip")
    child = open(conn, w.approver, "library")
    assert has_element?(child, "#library-clip-#{clip.id}")
    child |> element("#library-clip-#{clip.id} [data-role=clip-delete]") |> render_click()
    child |> element("[data-role=clip-delete-confirm]") |> render_click()
    refute has_element?(child, "#library-clip-#{clip.id}")
    assert has_element?(child, "[data-role=clips-library]", "No clips in Library.")
  end

  test "inflight guards explain refusal and revoked approvers cannot confirm a previously opened dialog",
       %{conn: conn, w: w} do
    clip = clip!(w, "Guard me")
    child = open(conn, w.approver)
    child |> element("[data-role=clip-delete]") |> render_click()
    {:ok, _} = Social.update_profile(w.org_id, w.profile, %{approver_user_ids: []})
    child |> element("[data-role=clip-delete-confirm]") |> render_click()
    assert Social.get_clip(w.org_id, clip.id)
    assert has_element?(child, "[data-role=clip-delete-error]")
    assert has_element?(child, "[data-role=clip-delete][disabled]")
  end
end
