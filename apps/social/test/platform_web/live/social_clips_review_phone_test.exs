defmodule PlatformWeb.SocialClipsReviewPhoneTest do
  @moduledoc """
  Clip Studio 3/9 (task 01a16662-8c00) stage 4: the Review bay's phone
  layout (the bottom bar, Up next, platform chips) and the ClipReview hook's
  server side (the hook root, the next/prev events). The ≤760px rules are
  Tailwind `max-[760px]:` variants, so these assert the markup the phone
  sees, not computed styles.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.AgentDrafts

  @titles [
    "Who makes Total War? Sorry, Creative Assembly",
    "Harder than the summit",
    "We moved the doomsday clock to 89 seconds",
    "GPU tax: who actually pays?"
  ]

  setup do
    w = render_world!()

    {:ok, ig} =
      Social.create_account(w.org_id, w.profile, %{platform: "instagram", handle: "@show.ig"})

    {:ok, yt} =
      Social.create_account(w.org_id, w.profile, %{platform: "youtube", handle: "@show.yt"})

    {:ok, tt} =
      Social.create_account(w.org_id, w.profile, %{platform: "tiktok", handle: "@show.tt"})

    octavius =
      Repo.insert!(%Platform.Agents.Agent{
        slug: "octavius-#{unique()}",
        name: "Octavius",
        metadata: %{"org_id" => w.org_id}
      })

    %{w: Map.merge(w, %{ig: ig, yt: yt, tt: tt, octavius: octavius})}
  end

  defp clip!(w, title, attrs \\ %{}) do
    file = stored_file!(w.project, "rendered clip #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        Map.merge(
          %{
            "file_id" => file.id,
            "title" => title,
            "episode_code" => "S2E14",
            "source_label" => "htc-clip-tool",
            "duration_s" => 42,
            "platforms" => ["instagram", "youtube"]
          },
          attrs
        ),
        w.octavius.id
      )

    clip
  end

  defp open(conn, user) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social?tab=clips&view=review")
    find_live_child(view, "ext-page-social")
  end

  defp bay(child), do: with_target(child, "#social-clips-review")

  defp selected?(child, clip),
    do: has_element?(child, "[data-role='clips-bay'][data-clip-id='#{clip.id}']")

  test "the bottom bar carries Reject and Approve with the desktop rules", %{conn: conn, w: w} do
    clip = clip!(w, "Phone decide")
    child = open(conn, w.approver)

    pbar = "[data-role='clips-pbar']"
    assert has_element?(child, pbar)

    for class <-
          ~w(fixed bottom-0 inset-x-0 z-30 bg-base-100/80 backdrop-blur border-t border-base-300) do
      assert has_element?(child, ~s(#{pbar}[class~="#{class}"]))
    end

    # Blank note: Reject disabled with the phone's title.
    assert has_element?(
             child,
             "#{pbar} [data-role='clips-pbar-reject'].btn.btn-outline[disabled][title='Add a note first']",
             "Reject"
           )

    assert has_element?(
             child,
             "#{pbar} [data-role='clips-pbar-approve'].btn.btn-primary.btn-lg:not([disabled])",
             "Approve and publish"
           )

    # A note enables Reject (no title), like the desktop footer.
    child
    |> form("[data-role='clips-details'] form[phx-change='note']")
    |> render_change(%{"note" => "payoff is cut off"})

    assert has_element?(child, "[data-role='clips-pbar-reject']:not([disabled]):not([title])")
    assert has_element?(child, "[data-role='clip-reject']:not([disabled])")

    # No platform: "Pick a platform", disabled, on both.
    for p <- ~w(instagram youtube),
        do: bay(child) |> render_click("toggle_platform", %{"platform" => p})

    assert has_element?(child, "[data-role='clips-pbar-approve'][disabled]", "Pick a platform")
    assert has_element?(child, "[data-role='clip-approve'][disabled]", "Pick a platform")

    # The bar fires the same approve event as the desktop button.
    bay(child) |> render_click("toggle_platform", %{"platform" => "youtube"})
    child |> element("[data-role='clips-pbar-approve']") |> render_click()

    assert %{review_status: "approved"} = Repo.reload!(clip)
    assert has_element?(child, "[data-role='clip-toast'][data-kind='approved']")
    refute has_element?(child, "[data-role='clips-pbar']")
  end

  test "the bottom bar's Reject fires the desktop reject", %{conn: conn, w: w} do
    clip = clip!(w, "Phone reject")
    child = open(conn, w.approver)

    child
    |> form("[data-role='clips-details'] form[phx-change='note']")
    |> render_change(%{"note" => "  too long in the intro  "})

    child |> element("[data-role='clips-pbar-reject']") |> render_click()

    assert %{review_status: "rejected", review_note: "too long in the intro"} =
             Repo.reload!(clip)
  end

  test "a non-approver gets no bottom bar", %{conn: conn, w: w} do
    clip!(w, "Read only")
    member = member!(user!(), w.org_id)
    child = open(conn, member)

    assert has_element?(child, "[data-role='clips-details']")
    refute has_element?(child, "[data-role='clips-pbar']")
    refute has_element?(child, "[data-role='clips-pbar-approve']")
    refute has_element?(child, "[data-role='clips-pbar-reject']")
    refute has_element?(child, "[data-role='clip-platform-chip']:not([disabled])")
  end

  test "platform chips mirror the toggles", %{conn: conn, w: w} do
    clip = clip!(w, "Chips")
    child = open(conn, w.approver)

    chips = "[data-role='clip-platform-chips']"
    assert has_element?(child, ~s(#{chips}[class~="hidden"][class~="max-[760px]:flex"]))
    assert has_element?(child, ~s([data-role='clip-post-to'][class~="max-[760px]:hidden"]))

    expect = fn checked ->
      for {platform, label} <- [
            {"instagram", "Instagram"},
            {"youtube", "YouTube"},
            {"tiktok", "TikTok"}
          ] do
        on? = platform in checked

        assert has_element?(
                 child,
                 "[data-role='clip-platform-chip'][role='checkbox'][data-platform='#{platform}'][aria-checked='#{on?}'].btn.btn-sm.rounded-full.#{if on?, do: "btn-primary", else: "btn-outline"}",
                 label
               )

        toggle = "[data-role='clip-platform-row'][data-platform='#{platform}'] input"

        assert has_element?(
                 child,
                 if(on?, do: "#{toggle}[checked]", else: "#{toggle}:not([checked])")
               )
      end
    end

    expect.(~w(instagram youtube))

    # A chip saves through the same toggle event; the switch follows.
    child |> element("[data-role='clip-platform-chip'][data-platform='tiktok']") |> render_click()
    expect.(~w(instagram youtube tiktok))
    assert Repo.reload!(clip).platforms == ["instagram", "youtube", "tiktok"]

    # A switch toggles; the chip follows.
    child
    |> element("[data-role='clip-platform-row'][data-platform='instagram'] input")
    |> render_click()

    expect.(~w(youtube tiktok))
  end

  test "the bay root carries the ClipReview hook", %{conn: conn, w: w} do
    clip!(w, "Hooked")
    child = open(conn, w.approver)

    assert has_element?(
             child,
             "#social-clips-review #social-clips-review-keys[phx-hook='ClipReview']"
           )

    assert has_element?(child, "#social-clips-review-keys [data-role='clips-bay']")
    assert has_element?(child, "#social-clips-review-keys [data-role='clip-scrub-fill']")
  end

  test "next and prev events move the selection", %{conn: conn, w: w} do
    [first, second, third, fourth] = Enum.map(@titles, &clip!(w, &1))
    child = open(conn, w.approver)

    assert selected?(child, first)
    # Up next: the two after the selected one, then "+N more".
    assert has_element?(child, "[data-role='clips-upnext']", "UP NEXT")

    assert has_element?(
             child,
             "[data-role='clips-upnext-item'][data-clip-id='#{second.id}']",
             "0:42"
           )

    assert has_element?(child, "[data-role='clips-upnext-item'][data-clip-id='#{third.id}']")
    refute has_element?(child, "[data-role='clips-upnext-item'][data-clip-id='#{fourth.id}']")
    assert has_element?(child, "[data-role='clips-upnext-more']", "+1 more")

    bay(child) |> render_hook("next", %{})
    assert selected?(child, second)
    bay(child) |> render_hook("next", %{})
    assert selected?(child, third)
    bay(child) |> render_hook("prev", %{})
    assert selected?(child, second)
    bay(child) |> render_hook("prev", %{})
    assert selected?(child, first)
    # Already first: prev stays put.
    bay(child) |> render_hook("prev", %{})
    assert selected?(child, first)

    # The Up next thumb picks.
    child
    |> element("[data-role='clips-upnext-item'][data-clip-id='#{third.id}']")
    |> render_click()

    assert selected?(child, third)
  end

  test "Up next reads last one with a single clip", %{conn: conn, w: w} do
    clip!(w, "Only one")
    child = open(conn, w.approver)

    refute has_element?(child, "[data-role='clips-upnext-item']")
    assert has_element?(child, "[data-role='clips-upnext-more']", "last one")
  end

  test "no element in the bay carries a swipe or touch binding", %{conn: conn, w: w} do
    Enum.each(@titles, &clip!(w, &1))
    child = open(conn, w.approver)
    html = child |> element("#social-clips-review") |> render()

    refute html =~ "phx-swipe"
    refute html =~ ~r/data-swipe/i
    refute html =~ ~r/\son(touch|pointer)\w*=/i
    refute html =~ ~r/phx-(touch|pointer)/i
  end
end
