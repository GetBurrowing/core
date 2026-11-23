defmodule PlatformWeb.SocialClipsReviewDecisionsTest do
  @moduledoc """
  Clip Studio 3/9 (task 01a16662-8c00) stage 3: decisions in the Review bay
  (`PlatformWeb.SocialClipsReview`): create drafts, reject with a
  note, the reject's undo toast, and live landings from the clips topic. Records are
  asserted through 2/9's own reads (`ClipLibrary.platform_status/1`,
  `ClipLibrary.clip_state/1`).
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Ecto.Query, only: [from: 2]

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{AgentDrafts, Clip, ClipDecisions, ClipJobs, ClipLibrary, Post}

  @titles [
    "Who makes Total War? Sorry, Creative Assembly",
    "Harder than the summit",
    "We moved the doomsday clock to 89 seconds"
  ]

  setup do
    w = render_world!()

    {:ok, ig} =
      Social.create_account(w.org_id, w.profile, %{platform: "instagram", handle: "@show.ig"})

    {:ok, yt} =
      Social.create_account(w.org_id, w.profile, %{platform: "youtube", handle: "@show.yt"})

    octavius =
      Repo.insert!(%Platform.Agents.Agent{
        slug: "octavius-#{unique()}",
        name: "Octavius",
        metadata: %{"org_id" => w.org_id}
      })

    %{w: Map.merge(w, %{ig: ig, yt: yt, octavius: octavius})}
  end

  defp clip!(w, title) do
    file = stored_file!(w.project, "rendered clip #{unique()}", "clip.mp4", "video/mp4")

    {:ok, clip} =
      AgentDrafts.submit_clip(
        w.scope,
        w.profile.id,
        %{
          "file_id" => file.id,
          "title" => title,
          "episode_code" => "S2E14",
          "source_label" => "htc-clip-tool",
          "duration_s" => 42,
          "platforms" => ["instagram", "youtube"]
        },
        w.octavius.id
      )

    clip
  end

  defp three!(w), do: Enum.map(@titles, &clip!(w, &1))

  defp open(conn, user) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social?tab=clips&view=review")
    find_live_child(view, "ext-page-social")
  end

  defp bay(child), do: with_target(child, "#social-clips-review")

  # A clips-topic broadcast reaches SocialLive, which send_update/3s the bay:
  # that update is queued behind whatever call is already waiting, so one
  # render lets it land before the assertions.
  defp sync(child), do: _ = render(child)

  defp posts(clip),
    do: Repo.all(from(p in Post, where: p.clip_id == ^clip.id, order_by: p.inserted_at))

  defp state(clip), do: clip |> Repo.reload!() |> ClipLibrary.clip_state()

  test "draft controls carry the displayed render and forged missing/foreign versions write nothing",
       %{conn: conn, w: w} do
    [first, second | _] = three!(w)
    child = open(conn, w.approver)
    selected_id = render_id!(first)
    assert has_element?(child, "[data-role='clip-draft'][phx-value-render_id='#{selected_id}']")

    assert has_element?(
             child,
             "[data-role='clips-pbar-draft'][phx-value-render_id='#{selected_id}']"
           )

    bay(child) |> render_click("draft", %{"id" => first.id})
    bay(child) |> render_click("draft", %{"id" => first.id, "render_id" => render_id!(second)})
    assert posts(first) == []
    assert Repo.reload!(first).review_status == "pending"
  end

  test "drafting with two platforms advances and the count drops", %{conn: conn, w: w} do
    [first, second, _] = three!(w)
    child = open(conn, w.approver)

    assert has_element?(child, "[data-role='clips-position']", "1 of 3")
    assert has_element?(child, "[data-role='clips-count'] b", "3 to review")

    child |> element("[data-role='clip-draft']") |> render_click()

    assert has_element?(child, "[data-role='clips-position']", "1 of 2")
    assert has_element?(child, "[data-role='clips-count'] b", "2 to review")
    assert has_element?(child, "[data-role='clips-queue-count']", "2")
    assert has_element?(child, "[data-role='clips-bay'][data-clip-id='#{second.id}']")
    refute has_element?(child, "[data-role='clips-queue-item'][data-clip-id='#{first.id}']")

    entries = first |> posts() |> Enum.map(&ClipLibrary.platform_status/1)
    assert entries |> Enum.map(& &1.account_id) |> Enum.sort() == Enum.sort([w.ig.id, w.yt.id])
    assert Enum.all?(entries, &(&1.state == :draft))
    assert Enum.all?(posts(first), &(&1.clip_id == first.id and &1.status == "draft"))
    assert Enum.all?(posts(first), &(is_nil(&1.publish_after) and is_nil(&1.approved_by_user_id)))
    assert state(first) == "In review"
  end

  test "drafting the last clip shows the empty state", %{conn: conn, w: w} do
    only = clip!(w, "Only one")
    child = open(conn, w.approver)

    bay(child) |> render_click("draft", %{"id" => only.id, "render_id" => render_id!(only)})

    assert has_element?(child, "[data-role='clips-empty']", "All caught up")
    assert has_element?(child, "[data-role='clips-count'] b", "0 to review")
  end

  test "drafting shows a plain toast: no undo, no publish time", %{conn: conn, w: w} do
    [first | _] = three!(w)
    child = open(conn, w.approver)

    child |> element("[data-role='clip-draft']") |> render_click()

    assert has_element?(child, "[data-role='clip-toast'][role='status'][data-kind='drafted']")

    assert has_element?(
             child,
             "[data-role='clip-toast-text']",
             "2 drafts created. Check their details and send them for review."
           )

    assert has_element?(
             child,
             "[data-role='clip-toast-drafts-link'][href='/m/social?profile=#{w.profile.id}&tab=queue#queue-drafts']"
           )

    assert has_element?(child, "[data-role='clip-toast'] .hero-check-circle-solid.text-success")
    refute has_element?(child, "[data-role='clip-toast-undo']")
    refute has_element?(child, "[data-role='clip-toast-bar']")
    refute render(child) =~ "publishing to"

    # Nothing was approved or armed: no card, no approver, no publish_after.
    assert [_, _] = posts(first)
    assert Enum.all?(posts(first), &(&1.status == "draft" and is_nil(&1.publish_after)))
  end

  test "the drafts confirmation lasts long enough to follow its link", %{conn: conn, w: w} do
    three!(w)
    child = open(conn, w.approver)

    child |> element("[data-role='clip-draft']") |> render_click()

    [until] =
      child
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role='clip-toast'][data-kind='drafted']")
      |> LazyHTML.attribute("data-until")

    left = String.to_integer(until) - System.system_time(:millisecond)
    assert left > 9_000 and left <= 10_000

    # Past the old 3.2 s lifetime (+ grace) the toast and its link are still there.
    Process.sleep(3_700)
    assert has_element?(child, "[data-role='clip-toast'][data-kind='drafted']")
    assert has_element?(child, "[data-role='clip-toast-drafts-link']", "Open drafts")

    # The link is a 44 px touch target (min-h-11 / min-w-11), phone included.
    assert has_element?(child, "[data-role='clip-toast-drafts-link'].min-h-11.min-w-11")
  end

  test "a refused draft toast keeps its short lifetime", %{conn: conn, w: w} do
    three!(w)
    child = open(conn, w.approver)
    owner = member!(user!(), w.org_id)
    {:ok, _} = Social.set_account_owner(w.org_id, w.yt, owner.id)

    child |> element("[data-role='clip-draft']") |> render_click()

    [until] =
      child
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-role='clip-toast'][data-kind='info']")
      |> LazyHTML.attribute("data-until")

    left = String.to_integer(until) - System.system_time(:millisecond)
    assert left > 0 and left <= 3_200
  end

  test "no control in the bay says approve or publish", %{conn: conn, w: w} do
    three!(w)
    child = open(conn, w.approver)
    html = render(child)
    assert html =~ "Create drafts"
    refute html =~ "Approve and publish"
    refute html =~ "publishes on approve"
    refute html =~ "no second approval"
  end

  test "a refused draft says nothing was changed and writes nothing", %{conn: conn, w: w} do
    [first | _] = three!(w)
    child = open(conn, w.approver)
    owner = member!(user!(), w.org_id)
    {:ok, _} = Social.set_account_owner(w.org_id, w.yt, owner.id)

    child |> element("[data-role='clip-draft']") |> render_click()

    assert has_element?(child, "[data-role='clip-toast'][data-kind='info']")
    assert has_element?(child, "[data-role='clip-toast-text']", "Only the account's owner")
    assert posts(first) == []
    assert Repo.reload!(first).review_status == "pending"
    assert has_element?(child, "[data-role='clips-count'] b", "3 to review")
  end

  test "reject needs a note", %{conn: conn, w: w} do
    [first | _] = three!(w)
    child = open(conn, w.approver)

    bay(child) |> render_click("reject", %{"id" => first.id, "note" => "   "})
    assert %Clip{review_status: "pending", review_note: nil} = Repo.reload!(first)
    refute has_element?(child, "[data-role='clip-toast']")

    child
    |> form("[data-role='clips-details'] form[phx-change='note']")
    |> render_change(%{"note" => "  too long in the intro  "})

    child |> element("[data-role='clip-reject']") |> render_click()

    assert %Clip{review_status: "rejected", review_note: "too long in the intro"} =
             Repo.reload!(first)

    assert state(first) == "Rejected"
    assert posts(first) == []
    assert has_element?(child, "[data-role='clip-toast'][data-kind='rejected']")
    assert has_element?(child, "[data-role='clip-toast'] .hero-x-circle-solid.text-error")

    assert has_element?(
             child,
             "[data-role='clip-toast-text']",
             "Rejected · Octavius gets your note"
           )

    assert has_element?(child, "[data-role='clip-toast-undo']", "Undo")
    assert has_element?(child, "[data-role='clips-count'] b", "2 to review")
  end

  test "undo restores a rejected clip", %{conn: conn, w: w} do
    [first, _second, _] = three!(w)
    child = open(conn, w.approver)

    bay(child) |> render_click("reject", %{"id" => first.id, "note" => "too long"})
    assert has_element?(child, "[data-role='clips-count'] b", "2 to review")

    child |> element("[data-role='clip-toast-undo']") |> render_click()

    assert has_element?(child, "[data-role='clips-count'] b", "3 to review")
    assert has_element?(child, "[data-role='clips-bay'][data-clip-id='#{first.id}']")

    assert has_element?(
             child,
             "[data-role='clips-queue-item'][aria-current='true'][data-clip-id='#{first.id}']"
           )

    assert state(first) == "In review"
    assert posts(first) == []
    assert has_element?(child, "[data-role='clip-toast'][data-kind='info']")

    assert has_element?(
             child,
             "[data-role='clip-toast-text']",
             "Restored “#{first.title}” to review"
           )

    refute has_element?(child, "[data-role='clip-toast-undo']")
  end

  test "a forged undo of a draft changes nothing: there is no window to undo", %{
    conn: conn,
    w: w
  } do
    [first | _] = three!(w)
    child = open(conn, w.approver)
    child |> element("[data-role='clip-draft']") |> render_click()
    before = posts(first)

    bay(child) |> render_click("undo", %{"id" => first.id, "render_id" => render_id!(first)})

    refute has_element?(child, "[data-role='clip-toast']")
    assert posts(first) == before
    assert Repo.reload!(first).review_status == "approved"
    assert state(first) == "In review"
  end

  test "a forged draft from a non-approver writes nothing", %{conn: conn, w: w} do
    clip = clip!(w, "Not yours to draft")
    member = member!(user!(), w.org_id)
    child = open(conn, member)

    render_click(with_target(child, "#social-clips-review"), "draft", %{
      "id" => clip.id,
      "render_id" => render_id!(clip)
    })

    render_click(with_target(child, "#social-clips-review"), "reject", %{
      "id" => clip.id,
      "note" => "forged"
    })

    assert posts(clip) == []
    assert %Clip{review_status: "pending"} = Repo.reload!(clip)
    refute has_element?(child, "[data-role='clip-toast']")
  end

  test "a forged draft on another org's clip writes nothing", %{conn: conn, w: w} do
    three!(w)
    other = render_world!()

    {:ok, foreign_ig} =
      Social.create_account(other.org_id, other.profile, %{platform: "instagram", handle: "@f"})

    {:ok, foreign} =
      AgentDrafts.submit_clip(
        other.scope,
        other.profile.id,
        %{
          "file_id" => stored_file!(other.project, "f #{unique()}", "f.mp4", "video/mp4").id,
          "title" => "FOREIGN",
          "platforms" => ["instagram"]
        },
        other.agent.id
      )

    child = open(conn, w.approver)

    bay(child)
    |> render_click("draft", %{
      "id" => foreign.id,
      "render_id" => render_id!(foreign),
      "account_ids" => [foreign_ig.id]
    })

    assert posts(foreign) == []
    assert %Clip{review_status: "pending"} = Repo.reload!(foreign)
    assert has_element?(child, "[data-role='clips-count'] b", "3 to review")
    refute has_element?(child, "[data-role='clip-toast']")
  end

  test "foreign account id is ignored", %{conn: conn, w: w} do
    [first | _] = three!(w)
    other = render_world!()

    {:ok, foreign_ig} =
      Social.create_account(other.org_id, other.profile, %{platform: "instagram", handle: "@f"})

    child = open(conn, w.approver)

    bay(child)
    |> render_click("draft", %{
      "id" => first.id,
      "render_id" => render_id!(first),
      "account_ids" => [foreign_ig.id]
    })

    account_ids = first |> posts() |> Enum.map(& &1.account_id) |> Enum.sort()
    assert account_ids == Enum.sort([w.ig.id, w.yt.id])
    refute foreign_ig.id in account_ids
  end

  test "an approver removed mid-session cannot draft", %{conn: conn, w: w} do
    [first | _] = three!(w)
    child = open(conn, w.approver)
    assert has_element?(child, "[data-role='clips-decide']")

    {:ok, _} =
      w.profile
      |> Ecto.Changeset.change(approver_user_ids: [])
      |> Repo.update()

    bay(child) |> render_click("draft", %{"id" => first.id, "render_id" => render_id!(first)})

    assert posts(first) == []
    assert %Clip{review_status: "pending"} = Repo.reload!(first)
    refute has_element?(child, "[data-role='clips-decide']")
    refute has_element?(child, "[data-role='clip-toast']")
  end

  test "a completed clip job lands as New clip in Review", %{conn: conn, w: w} do
    [_first | _] = three!(w)

    {:ok, %{job: job}} =
      ClipJobs.enqueue_new_clip(w.org_id, w.profile.id, w.approver.id, %{
        "source_file_id" => w.video.id,
        "in_s" => 2011.3,
        "out_s" => 2058.3,
        "title" => "GPU tax: who actually pays?"
      })

    {:ok, _} = ClipJobs.claim(w.scope, job.id, w.octavius.id)
    child = open(conn, w.approver)

    assert has_element?(child, "[data-role='clips-render-row'][data-job-id='#{job.id}']")
    assert has_element?(child, "[data-role='clips-count'] b", "3 to review")

    file = stored_file!(w.project, "landed #{unique()}", "landed.mp4", "video/mp4")

    {:ok, %{clip: landed}} =
      ClipJobs.complete(w.scope, job.id, w.octavius.id, %{
        "file_id" => file.id,
        "title" => "GPU tax: who actually pays?",
        "duration_s" => 47
      })

    sync(child)
    assert has_element?(child, "[data-role='clip-toast'][data-kind='info']")

    assert has_element?(
             child,
             "[data-role='clip-toast-text']",
             "New clip in Review · GPU tax: who actually pays?"
           )

    assert has_element?(
             child,
             "[data-role='clips-queue-item'][data-landed='true'][data-clip-id='#{landed.id}'].ring-info"
           )

    assert has_element?(child, "[data-role='clips-count'] b", "4 to review")
    refute has_element?(child, "[data-role='clips-render-row']")
  end

  test "a clip decided elsewhere leaves the list", %{conn: conn, w: w} do
    [first, second, third] = three!(w)
    child = open(conn, w.approver)

    # Not selected: it just leaves.
    {:ok, _} = ClipDecisions.reject_clip(w.org_id, third.id, w.approver.id, "elsewhere")
    sync(child)
    refute has_element?(child, "[data-role='clips-queue-item'][data-clip-id='#{third.id}']")
    assert has_element?(child, "[data-role='clips-position']", "1 of 2")

    # Selected: the next one is selected, with no toast.
    {:ok, _} =
      Platform.Social.LegacyClipApproval.approve_clip(w.org_id, first.id, w.approver.id, %{
        "render_id" => render_id!(first),
        "account_ids" => [w.ig.id]
      })

    sync(child)

    assert has_element?(child, "[data-role='clips-bay'][data-clip-id='#{second.id}']")
    assert has_element?(child, "[data-role='clips-position']", "1 of 1")
    refute has_element?(child, "[data-role='clip-toast']")
  end

  describe "drafted toast" do
    test "links to the Queue's Drafts group only when a draft was created", %{w: w} do
      alias PlatformWeb.SocialClipsReview

      assert %{drafts_path: path, text: text} =
               SocialClipsReview.drafted_toast([:p1, :p2], w.profile.id)

      assert path == "/m/social?profile=#{w.profile.id}&tab=queue#queue-drafts"
      assert text == "2 drafts created. Check their details and send them for review."

      assert %{text: "1 draft created. Check their details and send them for review."} =
               SocialClipsReview.drafted_toast([:p1], w.profile.id)

      assert SocialClipsReview.drafted_toast([], w.profile.id) == nil
    end
  end
end
