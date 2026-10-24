defmodule PlatformWeb.SocialConnectionsHealthTest do
  @moduledoc """
  Social authoring 9/11 (task 01a16c51-9cc5): Connections leads with account
  health, from the same `Platform.Social.Health` computation as the top
  bar's dot. `async: false`: the Fake's log is global.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.Post
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    Platform.Social.RateLimit.reset()
    ctx = approval_fixture()

    # ok: connected; down: pending (never connected); warn: refused yesterday.
    {:ok, ok} =
      Social.update_account(ctx.org_id, ctx.a, %{
        status: "connected",
        provider_account_ref: "acc_#{unique()}"
      })

    {:ok, down} =
      Social.create_account(ctx.org_id, ctx.profile, %{platform: "tiktok", handle: "@pending"})

    {:ok, warn} =
      Social.create_account(ctx.org_id, ctx.profile, %{
        platform: "x",
        handle: "@refused",
        status: "connected",
        provider_account_ref: "acc_#{unique()}"
      })

    Repo.delete!(ctx.d)

    post = approved_post!(ctx.org_id, warn, %{body: "refused yesterday"}, ctx.h1)

    {:ok, refused} =
      post
      |> Post.refusal_changeset("media_rejected", "The video is longer than 140 seconds.", nil)
      |> Repo.update()

    Repo.update_all(from(p in Post, where: p.id == ^refused.id),
      set: [updated_at: DateTime.add(DateTime.utc_now(), -1, :day)]
    )

    Map.merge(ctx, %{ok: ok, down: down, warn: warn, refused: refused})
  end

  defp open(conn, user, query \\ "") do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social" <> query)
    child = find_live_child(view, "ext-page-social")
    child |> element("[data-role='social-tab-button'][data-tab='connections']") |> render_click()
    child
  end

  defp row(account), do: "#accounts-#{account.id}"

  defp row_order(child) do
    child
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#social-accounts [data-role='social-account-row']")
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))
  end

  test "rows order down, warn, ok, each with a text pill and its reason", %{conn: conn} = ctx do
    child = open(conn, ctx.h1)

    assert row_order(child) == [
             "accounts-#{ctx.down.id}",
             "accounts-#{ctx.warn.id}",
             "accounts-#{ctx.ok.id}"
           ]

    assert has_element?(
             child,
             row(ctx.down) <> " [data-role='social-account-health']",
             "Not working"
           )

    assert has_element?(
             child,
             row(ctx.warn) <> " [data-role='social-account-health']",
             "Needs attention"
           )

    assert has_element?(child, row(ctx.ok) <> " [data-role='social-account-health']", "Healthy")

    assert has_element?(
             child,
             row(ctx.down) <> " [data-role='social-account-reason'][data-code='not_connected']",
             "Not connected yet"
           )

    assert has_element?(
             child,
             row(ctx.warn) <> " [data-role='social-account-reason'][data-code='refused']",
             "Last publish was not sent: The video is longer than 140 seconds."
           )

    refute has_element?(child, row(ctx.ok) <> " [data-role='social-account-reason']")

    assert has_element?(
             child,
             row(ctx.ok) <> " [data-role='social-account-approvers']",
             "Hana One, Hugo Two"
           )

    assert has_element?(
             child,
             row(ctx.ok) <> " [data-role='social-account-last-posted']",
             "Nothing posted yet"
           )
  end

  test "last posted links to the live post; the drafting agent shows when set",
       %{conn: conn} = ctx do
    post = approved_post!(ctx.org_id, ctx.ok, %{body: "out"}, ctx.h1)

    Repo.update_all(from(p in Post, where: p.id == ^post.id),
      set: [
        status: "published",
        published_at: DateTime.add(DateTime.utc_now(), -2, :day),
        external_url: "https://li.example.test/p/1"
      ]
    )

    agent = agent!()

    Repo.update_all(from(p in Social.Profile, where: p.id == ^ctx.profile.id),
      set: [drafting_agent_id: agent.id]
    )

    child = open(conn, ctx.h1)

    assert has_element?(
             child,
             row(ctx.ok) <>
               " [data-role='social-account-last-posted'] a[href='https://li.example.test/p/1']",
             "Last posted 2d ago"
           )

    assert has_element?(
             child,
             row(ctx.ok) <> " [data-role='social-account-drafting-agent']",
             agent.name
           )
  end

  test "an approver gets one fix per reason; Retry re-runs the guarded publish",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)

    assert has_element?(
             child,
             row(ctx.down) <> " [data-role='social-account-connect']",
             "Connect"
           )

    assert has_element?(
             child,
             row(ctx.warn) <> " [data-role='social-account-fix'][data-fix='retry']"
           )

    refute has_element?(child, row(ctx.ok) <> " [data-role='social-account-fix']")

    child
    |> element(row(ctx.warn) <> " [data-role='social-account-fix'][data-fix='retry']")
    |> render_click()

    assert [_] = Fake.calls(:publish)
    assert %{status: "scheduled", refused_reason: nil} = Repo.get!(Post, ctx.refused.id)
    assert has_element?(child, row(ctx.warn) <> " [data-role='social-account-health']", "Healthy")

    # Healthy again, so it re-sorts among the ok rows by name.
    assert row_order(child) == [
             "accounts-#{ctx.down.id}",
             "accounts-#{ctx.ok.id}",
             "accounts-#{ctx.warn.id}"
           ]
  end

  test "a non-approver sees health read-only, with no fix buttons", %{conn: conn} = ctx do
    child = open(conn, ctx.n)

    assert has_element?(
             child,
             row(ctx.down) <> " [data-role='social-account-health']",
             "Not working"
           )

    assert has_element?(
             child,
             row(ctx.warn) <> " [data-role='social-account-reason']",
             "140 seconds"
           )

    refute has_element?(child, "[data-role='social-account-fix']")
    refute has_element?(child, "[data-role='social-account-connect']")

    # The handler refuses too.
    render_click(child, "retry_publish", %{"post_id" => ctx.refused.id})
    assert Fake.calls(:publish) == []
  end

  test "the personal Instagram fix is a Reconnect on the connected row", %{conn: conn} = ctx do
    {:ok, ig} =
      Social.create_account(ctx.org_id, ctx.profile, %{
        platform: "instagram",
        handle: "@ig",
        status: "connected",
        provider_account_ref: "acc_#{unique()}",
        platform_account_type: "personal"
      })

    child = open(conn, ctx.h1)

    assert has_element?(
             child,
             row(ig) <> " [data-role='social-account-fix'][data-fix='connect']",
             "Reconnect"
           )
  end

  describe "the top bar dot reflects Health.profile/1" do
    test "it lists the same causes the rows show", %{conn: conn} = ctx do
      child = open(conn, ctx.h1)

      assert has_element?(
               child,
               "[data-role='social-health-dot'][aria-label*='TikTok on #{ctx.profile.name}']"
             )

      assert has_element?(
               child,
               "[data-role='social-health-dot'][aria-label*='1 post on #{ctx.profile.name}']"
             )
    end

    test "a personal Instagram account (a Health-only reason) lights it", %{conn: conn} do
      org = org_id!()
      viewer = member!(user!(), org)

      {:ok, profile} =
        Social.create_profile(org, %{name: "Solo #{unique()}", space_id: channel!(org).id})

      {:ok, _ig} =
        Social.create_account(org, profile, %{
          platform: "instagram",
          handle: "@solo",
          status: "connected",
          provider_account_ref: "acc_#{unique()}",
          platform_account_type: "personal"
        })

      child = open(conn, viewer)

      assert has_element?(
               child,
               "[data-role='social-health-dot'][aria-label*='is a personal account']"
             )
    end

    test "zero data: a new profile shows No accounts yet with Add account, and no dot", %{
      conn: conn
    } do
      org = org_id!()
      approver = member!(named_user!("Ada Approver"), org)

      {:ok, profile} =
        Social.create_profile(org, %{
          name: "Fresh #{unique()}",
          space_id: channel!(org).id,
          approver_user_ids: [approver.id]
        })

      child = open(conn, approver)

      assert has_element?(
               child,
               "[data-pane='connections'] [data-role='social-empty']",
               "No accounts yet"
             )

      assert has_element?(child, "[data-role='social-add-account']", "Add account")
      refute has_element?(child, "[data-role='social-health-dot']")
      assert Platform.Social.Health.by_profile([]) == %{}
      assert profile.id
    end
  end
end
