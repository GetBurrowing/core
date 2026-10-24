defmodule PlatformWeb.SocialLiveClipsTest do
  @moduledoc """
  Clip Studio 3/9 (task 01a16662-8c00) stage 1: the Clips tab in Social's
  nested LiveView, its URL params (`tab=clips&view=…&clip=…`, read once from
  `session["query"]`), the three LiveComponent mount points, and the
  clips-topic forwarding to the Review bay.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.AgentDrafts

  setup do
    w = render_world!()
    %{w: w}
  end

  defp pending_clip!(w, profile \\ nil, title \\ nil) do
    profile = profile || w.profile
    file = stored_file!(w.project, "rendered clip #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        profile.id,
        %{"file_id" => file.id, "title" => title || "Clip #{unique()}"},
        w.agent.id
      )

    clip
  end

  defp open(conn, user, query \\ "") do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social" <> query)
    find_live_child(view, "ext-page-social")
  end

  defp clips_tab, do: "[data-role='social-tab-button'][data-tab='clips']"
  defp count_sel, do: "#{clips_tab()} [data-role='social-clips-count']"

  test "the clips tab is listed with the pending count", %{conn: conn, w: w} do
    child = open(conn, w.approver)
    assert has_element?(child, clips_tab(), "Clips")
    assert has_element?(child, count_sel())
    refute has_element?(child, count_sel(), ~r/\d/)

    pending_clip!(w)
    pending_clip!(w)
    child = open(conn, w.approver)
    assert has_element?(child, count_sel(), "2")
  end

  test "?tab=clips&view=library opens Clips on Library", %{conn: conn, w: w} do
    child = open(conn, w.approver, "?tab=clips&view=library")
    assert has_element?(child, "[data-role='social-tab-body'][data-tab='clips']")
    assert has_element?(child, "[data-pane='clips']:not(.hidden) [data-role='clips-library']")
    assert has_element?(child, "[data-role='clips-review'][data-view='library']")

    assert has_element?(
             child,
             "[data-role='clips-view-button'][data-view='library'][aria-selected='true']"
           )
  end

  test "an unknown view or non-UUID clip param is ignored", %{conn: conn, w: w} do
    first = pending_clip!(w)
    child = open(conn, w.approver, "?tab=clips&view=bogus&clip=not-a-uuid")
    assert has_element?(child, "[data-role='clips-review'][data-view='review']")
    refute has_element?(child, "[data-role='clips-library']")
    assert has_element?(child, "[data-role='clips-bay'][data-clip-id='#{first.id}']")
  end

  test "a URL clip of this profile is selected", %{conn: conn, w: w} do
    _first = pending_clip!(w)
    second = pending_clip!(w)
    child = open(conn, w.approver, "?tab=clips&clip=#{second.id}")
    assert has_element?(child, "[data-role='clips-bay'][data-clip-id='#{second.id}']")
  end

  test "another org's clip id in the URL is refused", %{conn: conn, w: w} do
    own = pending_clip!(w, nil, "OWN-CLIP-TITLE")
    other = render_world!()
    foreign = pending_clip!(other, nil, "FOREIGN-CLIP-TITLE")

    child = open(conn, w.approver, "?tab=clips&view=review&clip=#{foreign.id}")
    assert has_element?(child, "[data-role='clips-bay'][data-clip-id='#{own.id}']")
    assert has_element?(child, "[data-role='clips-selected-title']", "OWN-CLIP-TITLE")
    refute render(child) =~ foreign.id
    refute render(child) =~ "FOREIGN-CLIP-TITLE"
  end

  test "the three mount points render", %{conn: conn, w: w} do
    child = open(conn, w.approver, "?tab=clips")

    assert has_element?(
             child,
             "[data-pane='clips'] #social-clips-review[data-role='clips-review']"
           )

    assert has_element?(child, "[data-pane='clips'] #social-clip-new[data-role='clip-new']")
    refute has_element?(child, "[data-role='clips-library']")

    child = open(conn, w.approver, "?tab=clips&view=library")
    assert has_element?(child, "[data-pane='clips'] #social-clips-library")
    assert has_element?(child, "[data-pane='clips'] #social-clips-review")
    assert has_element?(child, "[data-pane='clips'] #social-clip-new")

    # Placeholders stay hidden in this member.
    for role <- ~w(clip-edit-look clip-trim clip-cover-row clip-new-button),
        do: refute(has_element?(child, "[data-role='#{role}']"))
  end

  test "the segmented control switches the view and asks the hook to sync the URL",
       %{conn: conn, w: w} do
    clip = pending_clip!(w)
    child = open(conn, w.approver, "?tab=clips")

    child
    |> element("[data-role='clips-view-button'][data-view='library']")
    |> render_click()

    assert has_element?(child, "[data-role='clips-library']")
    assert has_element?(child, "[data-role='clips-review'][data-view='library']")
    assert_push_event(child, "clips:url", %{tab: "clips", view: "library", clip: clip_id})
    assert clip_id == clip.id
  end

  test "a read event recomputes can_decide? from the approver check", %{conn: conn, w: w} do
    pending_clip!(w)
    child = open(conn, w.approver, "?tab=clips")
    assert has_element?(child, "[data-role='clips-review'][data-can-decide='true']")

    {:ok, _} = Social.update_profile(w.org_id, w.profile, %{approver_user_ids: []})

    child
    |> element("[data-role='clips-view-button'][data-view='review']")
    |> render_click()

    assert has_element?(child, "[data-role='clips-review'][data-can-decide='false']")
  end

  test "a clips-topic broadcast reaches the review component", %{conn: conn, w: w} do
    child = open(conn, w.approver, "?tab=clips")
    assert has_element?(child, "[data-role='clips-empty']")
    refute has_element?(child, count_sel(), ~r/\d/)

    # Another profile's clip changes nothing.
    {:ok, other_profile} =
      Social.create_profile(w.org_id, %{
        name: "Other #{unique()}",
        project_id: w.project.id,
        space_id: channel!(w.org_id).id
      })

    other_clip = pending_clip!(w, other_profile)
    Social.broadcast_clip(other_clip)
    _ = render(child)
    refute has_element?(child, count_sel(), ~r/\d/)
    assert has_element?(child, "[data-role='clips-empty']")

    clip = pending_clip!(w)
    Social.broadcast_clip(Repo.reload!(clip))

    assert has_element?(child, count_sel(), "1")
    assert has_element?(child, "[data-role='clips-bay'][data-clip-id='#{clip.id}']")
  end
end
