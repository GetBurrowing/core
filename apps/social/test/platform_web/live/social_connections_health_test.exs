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

    post =
      approved_post!(
        ctx.org_id,
        warn,
        %{body: "refused yesterday", scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day)},
        ctx.h1
      )

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
    post =
      approved_post!(
        ctx.org_id,
        ctx.ok,
        %{body: "out", scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day)},
        ctx.h1
      )

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

  test "an approver gets one fix per reason; existing-job retry keeps the job",
       %{conn: conn} = ctx do
    Repo.update_all(from(p in Post, where: p.id == ^ctx.refused.id),
      set: [external_id: "existing-job"]
    )

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

    assert has_element?(child, row(ctx.warn) <> " [data-fix='retry'].min-h-11")

    refute has_element?(child, row(ctx.ok) <> " [data-role='social-account-fix']")

    child
    |> element(row(ctx.warn) <> " [data-role='social-account-fix'][data-fix='retry']")
    |> render_click()

    assert [{:retry, [_, "existing-job"], _}] = Fake.calls(:retry)
    assert Fake.calls(:publish) == []
    assert %{status: "scheduled", refused_reason: nil} = Repo.get!(Post, ctx.refused.id)
    assert has_element?(child, row(ctx.warn) <> " [data-role='social-account-health']", "Healthy")

    # Healthy again, so it re-sorts among the ok rows by name.
    assert row_order(child) == [
             "accounts-#{ctx.down.id}",
             "accounts-#{ctx.ok.id}",
             "accounts-#{ctx.warn.id}"
           ]
  end

  test "the Connections action refuses a rendered job A replaced by B before clicking",
       %{conn: conn} = ctx do
    Repo.update_all(from(p in Post, where: p.id == ^ctx.refused.id),
      set: [external_id: "rendered-A"]
    )

    child = open(conn, ctx.h1)

    Repo.update_all(from(p in Post, where: p.id == ^ctx.refused.id),
      set: [external_id: "current-B"]
    )

    before = Repo.get!(Post, ctx.refused.id)
    child |> element(row(ctx.warn) <> " [data-fix='retry']") |> render_click()
    assert Fake.calls() == []
    assert Repo.get!(Post, ctx.refused.id) == before
    assert render(child) =~ "The publish job changed, so nothing was retried."
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

  test "a published retry reports the saved classification", %{conn: conn} = ctx do
    Repo.update_all(from(p in Post, where: p.id == ^ctx.refused.id),
      set: [external_id: "existing-job"]
    )

    Fake.put_next(:retry, {:ok, %{status: :published, external_id: "existing-job"}})
    child = open(conn, ctx.h1)
    child |> element(row(ctx.warn) <> " [data-fix='retry']") |> render_click()
    assert Repo.get!(Post, ctx.refused.id).status == "published"
    assert render(child) =~ "Published."
  end

  test "a quality-blocked no-job retry requires investigation rather than another retry",
       %{conn: conn} = ctx do
    Repo.update!(Ecto.Changeset.change(ctx.profile, quality_reviewer_user_ids: [ctx.n.id]))
    before = Repo.get!(Post, ctx.refused.id)
    child = open(conn, ctx.h1)
    child |> element(row(ctx.warn) <> " [data-fix='retry']") |> render_click()
    at = DateTime.utc_now() |> DateTime.add(1, :day) |> Calendar.strftime("%Y-%m-%dT%H:%M:%S")
    child |> form("[data-role='retry-schedule']", %{at: at}) |> render_submit()

    assert has_element?(
             child,
             "[data-role='social-notice']",
             "This older post has no valid quality pass. Its publishing outcome needs separate investigation before a new job can be started."
           )

    assert Repo.get!(Post, ctx.refused.id) == before
    assert Fake.calls() == []
    refute has_element?(child, "[data-role='social-card-return-quality']")
  end

  test "an incomplete retry shows each missing publishing field", %{conn: conn} = ctx do
    Repo.update_all(from(a in Social.Account, where: a.id == ^ctx.warn.id),
      set: [platform: "youtube"]
    )

    child = open(conn, ctx.h1)
    child |> element(row(ctx.warn) <> " [data-fix='retry']") |> render_click()
    value = DateTime.utc_now() |> DateTime.add(1, :day) |> Calendar.strftime("%Y-%m-%dT%H:%M:%S")
    child |> form("[data-role='retry-schedule']", %{at: value}) |> render_submit()

    assert {:error, {:incomplete_post, _}} =
             Platform.Social.Publishing.retry_publish(ctx.org_id, ctx.refused.id, ctx.h1.id,
               scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day)
             )

    assert render(child) =~ "Add a video title"
    assert render(child) =~ "Add a video."
    assert Fake.calls(:publish) == []
  end

  test "a retry without a vendor job asks for a time before publishing", %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    child |> element(row(ctx.warn) <> " [data-fix='retry']") |> render_click()

    assert Fake.calls(:publish) == []
    assert has_element?(child, "[data-role='retry-schedule'] input[type='datetime-local']")
    assert has_element?(child, "[data-role='retry-schedule']", "Choose when to publish")
    assert Repo.get!(Post, ctx.refused.id).refused_reason == "media_rejected"
  end

  test "a past retry time is refused without publishing", %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    child |> element(row(ctx.warn) <> " [data-fix='retry']") |> render_click()
    child |> form("[data-role='retry-schedule']", %{at: "2020-01-01T12:00"}) |> render_submit()
    assert has_element?(child, "[data-role='retry-schedule']")
    assert render(child) =~ "Choose a future publish time"
    assert Fake.calls(:publish) == []
  end

  test "a job appearing while the chooser is open is not retried", %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    child |> element(row(ctx.warn) <> " [data-fix='retry']") |> render_click()

    Repo.update_all(from(p in Post, where: p.id == ^ctx.refused.id),
      set: [external_id: "new-job"]
    )

    at = DateTime.utc_now() |> DateTime.add(1, :day) |> Calendar.strftime("%Y-%m-%dT%H:%M:%S")
    child |> form("[data-role='retry-schedule']", %{at: at}) |> render_submit()
    assert Fake.calls(:publish) == []
    assert Fake.calls(:retry) == []
  end

  test "revoked approver cannot submit an already opened retry chooser", %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    child |> element(row(ctx.warn) <> " [data-fix='retry']") |> render_click()

    Repo.update_all(from(p in Social.Profile, where: p.id == ^ctx.profile.id),
      set: [approver_user_ids: [ctx.h2.id]]
    )

    value = DateTime.utc_now() |> DateTime.add(1, :day) |> Calendar.strftime("%Y-%m-%dT%H:%M:%S")
    child |> form("[data-role='retry-schedule']", %{at: value}) |> render_submit()
    assert Fake.calls(:publish) == []
    assert Fake.calls(:retry) == []
  end

  test "a future saved time is offered for confirmation and does not send", %{conn: conn} = ctx do
    at =
      DateTime.utc_now()
      |> DateTime.add(1, :day)
      |> DateTime.truncate(:second)
      |> Map.put(:microsecond, {0, 6})

    Repo.update_all(from(p in Post, where: p.id == ^ctx.refused.id), set: [scheduled_at: at])
    child = open(conn, ctx.h1)
    child |> element(row(ctx.warn) <> " [data-fix='retry']") |> render_click()
    value = Calendar.strftime(at, "%Y-%m-%dT%H:%M:%S")
    assert has_element?(child, "[data-role='retry-schedule'] input[value='#{value}']")
    assert Fake.calls(:publish) == []
  end

  test "a confirmed future time reaches the guarded retry and reports its saved status",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    child |> element(row(ctx.warn) <> " [data-fix='retry']") |> render_click()

    at =
      DateTime.utc_now()
      |> DateTime.add(1, :day)
      |> DateTime.truncate(:second)
      |> Map.put(:microsecond, {0, 6})

    value = Calendar.strftime(at, "%Y-%m-%dT%H:%M:%S")
    child |> form("[data-role='retry-schedule']", %{at: value}) |> render_submit()
    assert [{:publish, [_, %{scheduled_at: ^at}], _}] = Fake.calls(:publish)
    assert %{status: "scheduled", scheduled_at: ^at} = Repo.get!(Post, ctx.refused.id)
    assert render(child) =~ "Scheduled."
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
