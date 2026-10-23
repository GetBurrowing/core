defmodule PlatformWeb.SocialLiveQueueTest do
  @moduledoc """
  The Social tab's Queue (Social 7/7 stage 2): one row per needs_approval
  post of the selected profile, each the EXISTING approval card component
  (`PlatformWeb.SocialCardComponent`) on the post's live card, so a decision
  here and one in chat are the same code. `async: false`: the Fake's call
  log is global.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Approvals, ApprovalCard, Post, RateLimit}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    RateLimit.reset()
    ctx = approval_fixture()
    {post, card} = pending_post!(ctx, ctx.a, %{body: "HTC-Q1 SECRET-PREVIEW-BODY"})

    # A second profile in the same org, "Legacy" sorting after "HTC".
    legacy_space = channel!(ctx.org_id)

    {:ok, legacy} =
      Social.create_profile(ctx.org_id, %{
        name: "Legacy #{unique()}",
        space_id: legacy_space.id,
        approver_user_ids: [ctx.h1.id]
      })

    {:ok, legacy_account} =
      Social.create_account(ctx.org_id, legacy, %{platform: "youtube", handle: "Legacy channel"})

    {legacy_post, legacy_card} = pending_post!(ctx, legacy_account, %{body: "LEGACY-Q1 body"})

    Map.merge(ctx, %{
      post: post,
      card: card,
      legacy: legacy,
      legacy_post: legacy_post,
      legacy_card: legacy_card
    })
  end

  defp open(conn, user) do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social")
    find_live_child(view, "ext-page-social")
  end

  defp row(post), do: "#queue-#{post.id}"
  defp in_row(post, sel), do: "#{row(post)} #{sel}"

  defp fingerprint(card, user), do: Approvals.card_view(card.id, {:user, user.id}).fingerprint

  test "an approver sees each queued post as the approval card with preview and actions",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)

    assert has_element?(
             child,
             in_row(ctx.post, "#queue-card-#{ctx.card.id}[data-card-role='approver']")
           )

    assert has_element?(child, in_row(ctx.post, "[data-role='social-card-preview']"))
    assert has_element?(child, in_row(ctx.post, "[data-role='social-card-approve']"))
    assert has_element?(child, in_row(ctx.post, "[data-role='social-card-edit']"))
    assert has_element?(child, in_row(ctx.post, "[data-role='social-card-reject']"))
    assert render(child) =~ "SECRET-PREVIEW-BODY"
    refute has_element?(child, row(ctx.legacy_post))
  end

  test "Approve in the queue publishes once, decides the card the chat card shows, and a second approve is refused",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    assert has_element?(child, "[data-role='social-needs-approval']", "1 need approval")
    fp = fingerprint(ctx.card, ctx.h1)

    child |> element(in_row(ctx.post, "[data-role='social-card-approve']")) |> render_click()

    assert [{:publish, _, _}] = Fake.calls(:publish)
    assert Repo.get!(ApprovalCard, ctx.card.id).state == "decided"
    # What chat renders for the same canvas: card_view on the same card.
    assert Approvals.card_view(ctx.card.id, {:user, ctx.h2.id}).state == "decided"

    assert has_element?(
             child,
             in_row(ctx.post, "[data-role='social-card-status']"),
             "Approved by Hana One"
           )

    refute has_element?(child, in_row(ctx.post, "button"))
    # The row stays (decided) until the next profile load; the count drops.
    assert has_element?(child, "[data-role='social-needs-approval']", "0 need approval")
    assert has_element?(child, "[data-role='social-tab-button'][data-tab='queue']", "Queue (0)")

    html =
      child
      |> with_target("#queue-card-#{ctx.card.id}")
      |> render_click("social_card_approve", %{
        "canvas-id" => ctx.card.canvas_id,
        "fingerprint" => fp
      })

    assert html =~ "Someone already decided this post."
    assert length(Fake.calls(:publish)) == 1
  end

  test "Edit and Reject go through decide_edit and decide_reject", %{conn: conn} = ctx do
    {post2, _card2} = pending_post!(ctx, ctx.a, %{body: "to be rejected"})
    child = open(conn, ctx.h2)

    child |> element(in_row(ctx.post, "[data-role='social-card-edit']")) |> render_click()

    child
    |> element(in_row(ctx.post, "[data-role='social-card-editor']"))
    |> render_submit(%{"body" => "A tighter line"})

    assert {"A tighter line", "needs_approval"} ==
             (fn p -> {p.body, p.status} end).(Repo.get!(Post, ctx.post.id))

    assert has_element?(
             child,
             in_row(ctx.post, "[data-role='social-card-edited']"),
             "Edited by Hugo Two"
           )

    child |> element(in_row(post2, "[data-role='social-card-reject']")) |> render_click()

    child
    |> element(in_row(post2, "[data-role='social-card-reject-box']"))
    |> render_submit(%{"reason" => "Off brand"})

    p2 = Repo.get!(Post, post2.id)
    assert {p2.status, p2.rejection_reason} == {"draft", "Off brand"}

    assert has_element?(
             child,
             in_row(post2, "[data-role='social-card-status']"),
             "Rejected by Hugo Two"
           )

    assert Fake.calls(:publish) == []
  end

  test "a non-approver sees status lines only: no action element and no body",
       %{conn: conn} = ctx do
    {_d_post, _} = pending_post!(ctx, ctx.d, %{body: "DRAFT-ONLY-BODY"})
    child = open(conn, ctx.n)

    assert has_element?(child, in_row(ctx.post, "[data-card-role='viewer']"))

    assert has_element?(
             child,
             in_row(ctx.post, "[data-role='social-card-status']"),
             "Needs approval"
           )

    for sel <- ~w(approve edit reject copy) do
      refute has_element?(child, "#social-queue [data-role='social-card-#{sel}']")
    end

    refute has_element?(child, "#social-queue button")
    refute has_element?(child, "#social-queue [data-role='social-card-preview']")
    html = render(child)
    refute html =~ "SECRET-PREVIEW-BODY"
    refute html =~ "DRAFT-ONLY-BODY"
  end

  test "an agent-style viewer of a queued card is role viewer, with no actions or body", ctx do
    view = Approvals.card_view(ctx.card.id, {:agent, ctx.g.id})
    assert view.role == :viewer
    assert Map.get(view, :actions, []) == []
    refute Map.get(view, :body)
  end

  test "a draft_only account's row shows Copy and no Approve", %{conn: conn} = ctx do
    {d_post, d_card} = pending_post!(ctx, ctx.d, %{body: "DRAFT-ONLY-BODY"})
    child = open(conn, ctx.h1)

    assert has_element?(child, in_row(d_post, "[data-role='social-card-copy']"), "Copy text")
    refute has_element?(child, in_row(d_post, "[data-role='social-card-approve']"))

    html =
      child
      |> with_target("#queue-card-#{d_card.id}")
      |> render_click("social_card_approve", %{
        "canvas-id" => d_card.canvas_id,
        "fingerprint" => fingerprint(d_card, ctx.h1)
      })

    assert html =~ "This account is draft-only"
    assert Fake.calls(:publish) == []
  end

  test "switching HTC to Legacy leaves no HTC row in the DOM, and back again",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    assert has_element?(child, row(ctx.post))

    child |> form("#social-profile-switcher", %{profile_id: ctx.legacy.id}) |> render_change()

    refute has_element?(child, row(ctx.post))
    refute has_element?(child, "#queue-card-#{ctx.card.id}")
    assert has_element?(child, row(ctx.legacy_post))
    refute render(child) =~ "SECRET-PREVIEW-BODY"

    child |> form("#social-profile-switcher", %{profile_id: ctx.profile.id}) |> render_change()
    assert has_element?(child, row(ctx.post))
    refute has_element?(child, row(ctx.legacy_post))
  end

  test "a decision made in chat updates the queued card and the counts", %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    assert has_element?(child, in_row(ctx.post, "[data-role='social-card-approve']"))

    h2 = Platform.Accounts.get_user(ctx.h2.id)

    assert {:ok, _} =
             Approvals.decide_approve(ctx.card.canvas_id, h2, fingerprint(ctx.card, ctx.h2))

    assert has_element?(
             child,
             in_row(ctx.post, "[data-role='social-card-status']"),
             "Approved by Hugo Two"
           )

    refute has_element?(child, in_row(ctx.post, "[data-role='social-card-approve']"))
    assert has_element?(child, "[data-role='social-needs-approval']", "0 need approval")
  end

  test "an empty queue names the profile; a post with no live card says it is waiting",
       %{conn: conn} = ctx do
    {:ok, empty} =
      Social.create_profile(ctx.org_id, %{
        name: "Aardvark #{unique()}",
        space_id: channel!(ctx.org_id).id
      })

    {:ok, empty_account} = Social.create_account(ctx.org_id, empty, %{platform: "x"})
    child = open(conn, ctx.h1)

    child |> form("#social-profile-switcher", %{profile_id: empty.id}) |> render_change()

    assert has_element?(
             child,
             "[data-role='social-empty']",
             "Nothing waiting for approval on #{empty.name}."
           )

    # A needs_approval post whose card was never placed (written around the hook).
    {:ok, orphan} = Social.create_post(ctx.org_id, empty_account, %{body: "ORPHAN-BODY"})

    Repo.update_all(from(p in Post, where: p.id == ^orphan.id),
      set: [status: "needs_approval"]
    )

    assert Approvals.live_card(orphan.id) == nil

    child |> form("#social-profile-switcher", %{profile_id: ctx.profile.id}) |> render_change()
    child |> form("#social-profile-switcher", %{profile_id: empty.id}) |> render_change()

    assert has_element?(
             child,
             in_row(orphan, "[data-role='social-queue-waiting']"),
             "Waiting for its approval card."
           )

    refute has_element?(child, in_row(orphan, "button"))
    refute render(child) =~ "ORPHAN-BODY"
  end

  describe "a refused publish (task 01a165f1, stage 3)" do
    # An approved post whose publish was refused before the vendor: decided
    # through the real card (the Fake publishes), then put back to approved
    # with the refusal Publishing.publish_post/2 records.
    defp refused!(ctx, kind, attrs \\ []) do
      {post, card} = pending_post!(ctx, ctx.a, %{body: "REFUSED-#{kind} body"})
      h1 = Platform.Accounts.get_user(ctx.h1.id)
      {:ok, _} = Approvals.decide_approve(card.canvas_id, h1, fingerprint(card, ctx.h1))
      Fake.reset()

      set =
        Keyword.merge(
          [
            status: "approved",
            external_id: nil,
            external_url: nil,
            refused_reason: kind,
            refused_at: ~U[2026-10-22 23:21:00.000000Z],
            retry_after: nil,
            error: "Instagram Reels need a Business or Creator account."
          ],
          attrs
        )

      Repo.update_all(from(p in Post, where: p.id == ^post.id), set: set)
      {Repo.get!(Post, post.id), card}
    end

    defp admin!(user, org_id) do
      Repo.update_all(
        from(m in Platform.Tenancy.OrgMembership,
          where: m.user_id == ^user.id and m.org_id == ^org_id
        ),
        set: [role: "admin"]
      )
    end

    defp action(post), do: in_row(post, "[data-role='social-card-refusal-action']")

    test "each refusal renders its label, reason and one matching action", %{conn: conn} = ctx do
      {media, _} = refused!(ctx, "media_rejected")

      {limited, _} =
        refused!(ctx, "rate_limited",
          retry_after: DateTime.add(DateTime.utc_now(), 3600),
          error: "x"
        )

      {archived, _} = refused!(ctx, "account_archived")
      {unset, _} = refused!(ctx, "publisher_not_configured")
      admin!(ctx.h1, ctx.org_id)

      child = open(conn, ctx.h1)
      status = "[data-role='social-card-status']"
      reason = "[data-role='social-card-refusal-reason']"

      assert has_element?(child, in_row(media, status <> "[data-dot='error']"), "Not published")
      refute has_element?(child, in_row(media, status), "Approved")

      assert has_element?(
               child,
               in_row(media, reason),
               "Instagram Reels need a Business or Creator account."
             )

      assert has_element?(
               child,
               in_row(media, "[data-role='social-card-refused-at']"),
               "Refused 23:21"
             )

      assert has_element?(
               child,
               action(media) <> "[data-action='retry_publish']",
               "Retry publish"
             )

      assert has_element?(
               child,
               in_row(limited, status <> "[data-dot='warning']"),
               "Waiting to retry"
             )

      clock = Calendar.strftime(limited.retry_after, "%H:%M")

      assert has_element?(
               child,
               in_row(limited, reason),
               "LinkedIn's posting limit is reached. This post goes out at"
             )

      assert has_element?(child, in_row(limited, "[data-role='social-card-retry-clock']"), clock)

      assert has_element?(child, in_row(archived, status), "Not published")

      assert has_element?(
               child,
               in_row(archived, reason),
               "The LinkedIn account is disconnected."
             )

      assert has_element?(
               child,
               action(archived) <> "[data-action='reconnect'][href*='tab=connections']",
               "Reconnect account"
             )

      assert has_element?(
               child,
               in_row(unset, reason),
               "Publishing isn't set up for this profile."
             )

      assert has_element?(
               child,
               action(unset) <> "[data-action='open_settings'][href*='tab=settings']",
               "Open settings"
             )

      # Visible text only: the refusal kind rides in data-refusal, never in copy.
      for post <- [media, limited, archived, unset] do
        text =
          child
          |> element(in_row(post, "[data-role='social-card-refusal']"))
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.text()

        refute text =~ ~r/media_rejected|rate_limited|account_archived|publisher_not_configured/
      end
    end

    test "rate_limited shows Publish now disabled, never Retry publish", %{conn: conn} = ctx do
      {limited, _} =
        refused!(ctx, "rate_limited", retry_after: DateTime.add(DateTime.utc_now(), 3600))

      child = open(conn, ctx.h1)

      assert has_element?(
               child,
               action(limited) <> "[data-action='publish_now'][disabled]",
               "Publish now"
             )

      refute has_element?(child, in_row(limited, "[data-action='retry_publish']"))
    end

    test "a viewer and an approver who is not an admin get no action", %{conn: conn} = ctx do
      {media, _} = refused!(ctx, "media_rejected")
      {unset, _} = refused!(ctx, "publisher_not_configured")

      viewer = open(conn, ctx.n)

      assert has_element?(
               viewer,
               in_row(media, "[data-role='social-card-status']"),
               "Not published"
             )

      assert has_element?(
               viewer,
               in_row(media, "[data-role='social-card-refusal-reason']"),
               "Instagram Reels need a Business or Creator account."
             )

      refute has_element?(viewer, "#social-queue [data-role='social-card-refusal-action']")
      refute has_element?(viewer, "#social-queue button")

      # H2 approves on the profile but is not an org admin: no Open settings.
      approver = open(build_conn(), ctx.h2)
      assert has_element?(approver, action(media), "Retry publish")
      refute has_element?(approver, action(unset))
    end

    test "Retry publishes via the Fake and clears the refusal", %{conn: conn} = ctx do
      {media, _} = refused!(ctx, "media_rejected")
      child = open(conn, ctx.h1)

      assert has_element?(child, action(media) <> "[phx-disable-with='Publishing']")
      child |> element(action(media)) |> render_click()

      assert [{:publish, _, _}] = Fake.calls(:publish)
      row = Repo.get!(Post, media.id)
      assert {row.status, row.refused_reason, row.refused_at} == {"scheduled", nil, nil}
      refute has_element?(child, in_row(media, "[data-role='social-card-refusal']"))
      refute has_element?(child, in_row(media, "[data-role='social-card-notice']"))
      assert has_element?(child, in_row(media, "[data-role='social-card-status']"), "Approved by")
    end

    test "a second refusal updates the reason in place with no notice", %{conn: conn} = ctx do
      {media, _} = refused!(ctx, "media_rejected", error: "old reason.")
      child = open(conn, ctx.h1)

      previous = Application.get_env(:social, :publisher)
      Application.delete_env(:social, :publisher)
      on_exit(fn -> Application.put_env(:social, :publisher, previous) end)

      child |> element(action(media)) |> render_click()

      assert has_element?(
               child,
               in_row(media, "[data-role='social-card-refusal-reason']"),
               "Publishing isn't set up for this profile."
             )

      assert [_one] =
               child
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query(in_row(media, "[data-role='social-card-refusal']"))
               |> Enum.to_list()

      refute has_element?(child, in_row(media, "[data-role='social-card-notice']"))
    end

    test "the queue lists refused posts, and Not published filters to them",
         %{conn: conn} = ctx do
      {media, _} = refused!(ctx, "media_rejected")
      child = open(conn, ctx.h1)

      assert has_element?(child, row(ctx.post))
      assert has_element?(child, row(media))

      child
      |> element("[data-role='social-queue-chip'][data-filter='not_published']", "Not published")
      |> render_click()

      assert has_element?(
               child,
               "[data-role='social-queue-chip'][aria-pressed='true']",
               "Not published"
             )

      assert has_element?(child, row(media))
      refute has_element?(child, row(ctx.post))

      child
      |> element(
        "[data-role='social-queue-chip'][data-filter='needs_approval']",
        "Needs approval"
      )
      |> render_click()

      assert has_element?(child, row(ctx.post))
      refute has_element?(child, row(media))
    end

    test "a healthy approved card is unchanged and the queue shows no filter",
         %{conn: conn} = ctx do
      {post, card} = pending_post!(ctx, ctx.a, %{body: "HEALTHY"})
      h1 = Platform.Accounts.get_user(ctx.h1.id)
      {:ok, _} = Approvals.decide_approve(card.canvas_id, h1, fingerprint(card, ctx.h1))

      view = Approvals.card_view(card.id, {:user, ctx.h1.id})
      assert view.refusal == nil
      refute Map.has_key?(view.status, :dot)
      assert view.status.text =~ "Approved by Hana One"

      child = open(conn, ctx.h1)
      refute has_element?(child, "[data-role='social-queue-filter']")
      refute has_element?(child, row(post))
      refute has_element?(child, "[data-role='social-card-refusal']")
    end
  end
end
