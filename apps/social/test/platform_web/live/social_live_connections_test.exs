defmodule PlatformWeb.SocialLiveConnectionsTest do
  @moduledoc """
  The Social tab's Connections and Settings (Social 7/7 stage 4): account
  rows with their state and approval mode, Connect/Reconnect through the
  Publisher's connect_url/2, and profile settings. Every write re-checks
  approver_check/3 server-side. `async: false`: the Fake's log and the
  publisher config are global.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Repo
  alias Platform.Social
  alias Platform.Social.{Account, Profile}
  alias Platform.Social.Publisher.Fake

  setup do
    Fake.reset()
    ctx = approval_fixture()
    # a: never connected; d: connected; r: needs reauth.
    {:ok, d} = Social.update_account(ctx.org_id, ctx.d, %{status: "connected"})

    {:ok, r} =
      Social.create_account(ctx.org_id, ctx.profile, %{
        platform: "youtube",
        handle: "HTC channel",
        status: "reauth_needed"
      })

    {:ok, fabrikam} =
      Social.create_profile(ctx.org_id, %{
        name: "Fabrikam #{unique()}",
        space_id: channel!(ctx.org_id).id,
        approver_user_ids: [ctx.h1.id]
      })

    {:ok, fabrikam_account} =
      Social.create_account(ctx.org_id, fabrikam, %{platform: "youtube", handle: "Fabrikam channel"})

    Map.merge(ctx, %{d: d, r: r, fabrikam: fabrikam, fabrikam_account: fabrikam_account})
  end

  defp open(conn, user, tab \\ "connections") do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social")
    child = find_live_child(view, "ext-page-social")
    child |> element("[data-role='social-tab-button'][data-tab='#{tab}']") |> render_click()
    child
  end

  defp row(account), do: "#accounts-#{account.id}"

  test "one row per account with platform, handle, mode label and state", %{conn: conn} = ctx do
    child = open(conn, ctx.n)

    assert has_element?(
             child,
             row(ctx.a) <> " [data-role='social-account-handle']",
             "@htc_official"
           )

    assert has_element?(
             child,
             row(ctx.a) <> " [data-role='social-account-mode']",
             "Approve first"
           )

    assert has_element?(child, row(ctx.d) <> " [data-role='social-account-mode']", "Draft-only")
    assert has_element?(child, row(ctx.d) <> " [data-state='connected']", "Connected")

    assert has_element?(
             child,
             row(ctx.r) <> " [data-state='reauth_needed'] .badge-warning",
             "Reconnect"
           )

    assert has_element?(child, row(ctx.a) <> " [data-state='none']", "Not connected")
    # A non-approver gets read-only labels: no Connect, no mode select.
    refute has_element?(child, "[data-role='social-account-connect']")
    refute has_element?(child, "select[data-role='social-account-mode']")
  end

  test "an approver's Connect redirects to the publisher's URL with this install's /m/social",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    assert has_element?(child, row(ctx.a) <> " [data-role='social-account-connect']", "Connect")
    assert has_element?(child, row(ctx.r) <> " [data-role='social-account-connect']", "Reconnect")
    refute has_element?(child, row(ctx.a) <> " .btn-primary")

    child |> element(row(ctx.a) <> " [data-role='social-account-connect']") |> render_click()

    redirect_url = PlatformWeb.Endpoint.url() <> "/m/social"

    expected =
      "https://fake-publisher.example.test/connect/#{ctx.a.id}?" <>
        URI.encode_query(%{redirect_url: redirect_url})

    assert_redirect(child, expected)
    assert [{:connect_url, [%Account{id: id}, opts], _}] = Fake.calls(:connect_url)
    assert id == ctx.a.id
    assert opts[:redirect_url] == redirect_url
  end

  test "with no publisher configured, Connect says so and goes nowhere", %{conn: conn} = ctx do
    previous = Application.get_env(:social, :publisher)
    Application.delete_env(:social, :publisher)
    on_exit(fn -> Application.put_env(:social, :publisher, previous) end)

    child = open(conn, ctx.h1)
    child |> element(row(ctx.a) <> " [data-role='social-account-connect']") |> render_click()

    assert has_element?(
             child,
             "[data-role='social-notice']",
             "Publishing isn't configured on this install."
           )
  end

  test "the mode select offers exactly Approve first and Draft-only, and saves",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    html = render(child)
    refute html =~ ~r/autonomous/i

    options =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#social-mode-select-#{ctx.a.id} option")
      |> Enum.map(&LazyHTML.text/1)
      |> Enum.map(&String.trim/1)

    assert options == ["Draft-only", "Approve first"]

    child
    |> form("#social-mode-#{ctx.a.id}", %{account_id: ctx.a.id, approval_mode: "draft_only"})
    |> render_change()

    assert Repo.get!(Account, ctx.a.id).approval_mode == "draft_only"

    assert has_element?(
             child,
             "#social-mode-select-#{ctx.a.id} option[selected][value='draft_only']"
           )

    render_hook(child, "set_mode", %{"account_id" => ctx.a.id, "approval_mode" => "autonomous"})
    assert Repo.get!(Account, ctx.a.id).approval_mode == "draft_only"
  end

  test "a non-approver's forged connect, mode and settings events change nothing",
       %{conn: conn} = ctx do
    child = open(conn, ctx.n)
    before = Repo.get!(Profile, ctx.profile.id)

    render_hook(child, "connect_account", %{"id" => ctx.a.id})
    assert Fake.calls(:connect_url) == []

    render_hook(child, "set_mode", %{"account_id" => ctx.a.id, "approval_mode" => "draft_only"})
    assert Repo.get!(Account, ctx.a.id).approval_mode == "approve_first"

    render_hook(child, "save_settings", %{
      "profile" => %{"home_url" => "https://evil.example", "approver_user_ids" => [ctx.n.id]}
    })

    after_ = Repo.get!(Profile, ctx.profile.id)

    assert {after_.home_url, after_.approver_user_ids} ==
             {before.home_url, before.approver_user_ids}

    assert has_element?(child, "[data-role='social-notice']", "Only an approver")
  end

  test "an approver cannot act on another profile's account by a forged id",
       %{conn: conn} = ctx do
    other = approval_fixture()
    child = open(conn, ctx.h1)

    render_hook(child, "connect_account", %{"id" => other.a.id})
    render_hook(child, "set_mode", %{"account_id" => other.a.id, "approval_mode" => "draft_only"})

    assert Fake.calls(:connect_url) == []
    assert Repo.get!(Account, other.a.id).approval_mode == "approve_first"
  end

  test "settings: the approver picker lists people only, the channel is a picker by name, and saves",
       %{conn: conn} = ctx do
    other_space = channel!(ctx.org_id, %{name: "HTC approvals"})
    child = open(conn, ctx.h1, "settings")
    html = render(child)

    options =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("select[name='profile[approver_user_ids][]'] option")
      |> Enum.map(&LazyHTML.attribute(&1, "value"))
      |> List.flatten()

    assert ctx.h1.id in options and ctx.n.id in options
    refute ctx.g.id in options
    refute html =~ ctx.g.name

    assert has_element?(
             child,
             "select[name='profile[space_id]'] option[value='#{other_space.id}']",
             "HTC approvals"
           )

    child
    |> form("#social-settings-form", %{
      profile: %{
        home_url: "https://htc.example/show",
        voice_notes: "Warm, short.",
        default_hashtags: "#htc, #podcast",
        approver_user_ids: [ctx.h1.id, ctx.n.id],
        space_id: other_space.id
      }
    })
    |> render_submit()

    p = Repo.get!(Profile, ctx.profile.id)
    assert p.home_url == "https://htc.example/show"
    assert p.voice_notes == "Warm, short."
    assert p.default_hashtags == ["#htc", "#podcast"]
    assert Enum.sort(p.approver_user_ids) == Enum.sort([ctx.h1.id, ctx.n.id])
    assert p.space_id == other_space.id
    assert has_element?(child, "[data-role='social-notice']", "Settings saved.")
  end

  test "a forged agent id or foreign space is dropped on save", %{conn: conn} = ctx do
    foreign = channel!(org_id!())
    child = open(conn, ctx.h1, "settings")

    render_hook(child, "save_settings", %{
      "profile" => %{
        "approver_user_ids" => [ctx.h1.id, ctx.g.id],
        "space_id" => foreign.id
      }
    })

    p = Repo.get!(Profile, ctx.profile.id)
    assert p.approver_user_ids == [ctx.h1.id]
    assert p.space_id == ctx.space.id
  end

  test "a non-approver sees settings read-only", %{conn: conn} = ctx do
    child = open(conn, ctx.n, "settings")
    assert has_element?(child, "[data-role='social-settings-readonly']")
    refute has_element?(child, "#social-settings-form")
  end

  test "a profile switch resets the accounts stream; an empty one names the profile",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    assert has_element?(child, row(ctx.a))

    child |> form("#social-profile-switcher", %{profile_id: ctx.fabrikam.id}) |> render_change()
    refute has_element?(child, row(ctx.a))
    refute has_element?(child, row(ctx.d))
    assert has_element?(child, row(ctx.fabrikam_account), "Fabrikam channel")

    {:ok, empty} =
      Social.create_profile(ctx.org_id, %{
        name: "Empty #{unique()}",
        space_id: channel!(ctx.org_id).id
      })

    child = open(conn, ctx.h1)
    child |> form("#social-profile-switcher", %{profile_id: empty.id}) |> render_change()

    assert has_element?(
             child,
             "[data-pane='connections'] [data-role='social-empty']",
             "No accounts connected for #{empty.name} yet"
           )
  end
end
