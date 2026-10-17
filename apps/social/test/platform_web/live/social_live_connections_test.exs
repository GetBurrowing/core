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

  # ── Add account (task 01a14801 stage 3) ─────────────────────────────

  describe "Add account" do
    @auth_url "https://vendor.example.test/oauth"
    @add "[data-role='social-add-account']"
    @connect "[data-role='social-account-connect']"

    setup ctx do
      {:ok, empty} =
        Social.create_profile(ctx.org_id, %{
          name: "Empty #{unique()}",
          space_id: channel!(ctx.org_id).id,
          approver_user_ids: [ctx.h1.id]
        })

      %{empty: empty}
    end

    defp select_zernio(opts \\ [key?: true], ctx) do
      previous = Application.get_env(:social, :publisher)
      Application.put_env(:social, :publisher, Platform.Social.Publisher.Zernio)
      on_exit(fn -> Application.put_env(:social, :publisher, previous) end)

      if opts[:key?] do
        {:ok, _} = Platform.Social.Secrets.put_zernio_api_key("zk-add-not-real", ctx.h1)
      end

      :ok
    end

    # The stub only reports what it was sent; the TEST asserts it. `answer`
    # gets the conn and picks the response, so one test can fail one leg.
    defp record_requests(answer) do
      test = self()

      Req.Test.stub(Platform.Social.Publisher.Zernio, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test, {:zernio_request, conn.method, conn.request_path, conn.query_params})
        answer.(conn)
      end)
    end

    defp zernio_ok(profile_id \\ "zprof_added_1") do
      fn
        %{method: "POST", request_path: "/api/v1/profiles"} = conn ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"message" => "created", "profile" => %{"_id" => profile_id}})

        %{method: "GET", request_path: "/api/v1/connect/" <> _} = conn ->
          Req.Test.json(conn, %{"authUrl" => @auth_url})

        # Opening Connections with a pending row on a linked profile asks
        # the vendor's account list (task 01a14807); nothing is listed here.
        %{method: "GET", request_path: "/api/v1/accounts"} = conn ->
          Req.Test.json(conn, %{"accounts" => []})
      end
    end

    defp requests(acc \\ []) do
      receive do
        {:zernio_request, method, path, params} -> requests([{method, path, params} | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp open_profile(conn, user, profile) do
      conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, "/m/social")
      child = find_live_child(view, "ext-page-social")
      Req.Test.allow(Platform.Social.Publisher.Zernio, self(), child.pid)
      child |> form("#social-profile-switcher", %{profile_id: profile.id}) |> render_change()

      child
      |> element("[data-role='social-tab-button'][data-tab='connections']")
      |> render_click()

      child
    end

    defp add(child, platform) do
      child |> element(@add) |> render_click()
      child |> form("#social-add-account-form", %{platform: platform}) |> render_submit()
    end

    defp accounts_of(profile), do: Social.list_accounts(profile.org_id, profile_id: profile.id)
    defp ref_of(profile), do: Repo.get!(Profile, profile.id).provider_profile_ref

    test "(a) Zernio: an approver adds LinkedIn on an empty profile and is sent to authUrl; the vendor profile is created first",
         %{conn: conn} = ctx do
      select_zernio(ctx)
      record_requests(zernio_ok())

      child = open_profile(conn, ctx.h1, ctx.empty)
      assert has_element?(child, "[data-pane='connections'] [data-role='social-empty']")
      assert has_element?(child, @add, "Add account")

      add(child, "linkedin")
      assert_redirect(child, @auth_url)

      assert [{"POST", "/api/v1/profiles", _}, {"GET", "/api/v1/connect/linkedin", params}] =
               requests()

      assert params["profileId"] == "zprof_added_1"
      assert params["redirect_url"] == PlatformWeb.Endpoint.url() <> "/m/social"
      assert ref_of(ctx.empty) == "zprof_added_1"
      assert [%Account{platform: "linkedin", status: nil}] = accounts_of(ctx.empty)
    end

    test "(b) a second Add account on the same profile makes no second POST /v1/profiles",
         %{conn: conn} = ctx do
      select_zernio(ctx)
      record_requests(zernio_ok())

      conn |> open_profile(ctx.h1, ctx.empty) |> add("linkedin")
      assert [{"POST", _, _}, {"GET", _, _}] = requests()

      child = open_profile(build_conn(), ctx.h1, ctx.empty)
      add(child, "x")
      assert_redirect(child, @auth_url)

      # The reopen reconciles the still-pending linkedin row (one list GET);
      # the add itself makes only the connect GET, no second profile POST.
      assert [
               {"GET", "/api/v1/accounts", %{"profileId" => "zprof_added_1"}},
               {"GET", "/api/v1/connect/twitter", %{"profileId" => "zprof_added_1"}}
             ] = requests()

      assert accounts_of(ctx.empty) |> Enum.map(& &1.platform) |> Enum.sort() == ["linkedin", "x"]
    end

    test "(c) an agent viewer sees no control and its forged add is refused; the approver's identical event succeeds",
         %{conn: conn} = ctx do
      select_zernio(ctx)
      record_requests(zernio_ok())
      event = %{"platform" => "linkedin"}

      {:ok, g_view, _html} =
        live_isolated(conn, PlatformWeb.SocialLive, session: %{"user_id" => ctx.g.id})

      Req.Test.allow(Platform.Social.Publisher.Zernio, self(), g_view.pid)
      refute has_element?(g_view, @add)
      render_hook(g_view, "add_account", event)
      assert Process.alive?(g_view.pid)

      assert accounts_of(ctx.empty) == []
      assert requests() == []
      assert ref_of(ctx.empty) == nil

      # Positive control: the approver sends the identical event.
      h_child = open_profile(build_conn(), ctx.h1, ctx.empty)
      render_hook(h_child, "add_account", event)
      assert_redirect(h_child, @auth_url)
      assert [%Account{platform: "linkedin"}] = accounts_of(ctx.empty)
    end

    test "(c) a non-approver human sees no control and their forged add is refused; the approver's identical event succeeds",
         %{conn: conn} = ctx do
      select_zernio(ctx)
      record_requests(zernio_ok())
      event = %{"platform" => "linkedin"}

      n_child = open_profile(conn, ctx.n, ctx.empty)
      refute has_element?(n_child, @add)
      refute has_element?(n_child, "#social-add-account-form")
      render_hook(n_child, "add_account", event)

      assert has_element?(
               n_child,
               "[data-role='social-notice']",
               "Only an approver of this profile can change it."
             )

      assert accounts_of(ctx.empty) == []
      assert requests() == []
      assert ref_of(ctx.empty) == nil

      # Positive control: the approver sends the identical event.
      h_child = open_profile(build_conn(), ctx.h1, ctx.empty)
      render_hook(h_child, "add_account", event)
      assert_redirect(h_child, @auth_url)
      assert [%Account{platform: "linkedin"}] = accounts_of(ctx.empty)
    end

    test "(d) under the Fake: no Zernio request, the redirect is the Fake's URL and the ref stays nil",
         %{conn: conn} = ctx do
      record_requests(zernio_ok())

      child = open_profile(conn, ctx.h1, ctx.empty)
      add(child, "linkedin")

      assert [%Account{id: id, platform: "linkedin"}] = accounts_of(ctx.empty)

      expected =
        "https://fake-publisher.example.test/connect/#{id}?" <>
          URI.encode_query(%{redirect_url: PlatformWeb.Endpoint.url() <> "/m/social"})

      assert_redirect(child, expected)
      assert requests() == []
      assert ref_of(ctx.empty) == nil
    end

    test "(e) Zernio with no key: the control is hidden and a forged add creates nothing",
         %{conn: conn} = ctx do
      select_zernio([key?: false], ctx)
      record_requests(zernio_ok())

      child = open_profile(conn, ctx.h1, ctx.empty)
      assert has_element?(child, "[data-role='social-zernio-required']")
      refute has_element?(child, @add)

      render_hook(child, "add_account", %{"platform" => "linkedin"})

      assert has_element?(
               child,
               "[data-role='social-notice']",
               "Add the Zernio API key in Settings first."
             )

      assert accounts_of(ctx.empty) == []
      assert requests() == []
      assert ref_of(ctx.empty) == nil
    end

    test "(f) a create-profile 500 leaves no row and no ref", %{conn: conn} = ctx do
      select_zernio(ctx)

      record_requests(fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "down"})
      end)

      child = open_profile(conn, ctx.h1, ctx.empty)
      add(child, "linkedin")

      assert has_element?(
               child,
               "[data-role='social-notice']",
               "Couldn't set up this profile at Zernio. Try again."
             )

      assert [{"POST", "/api/v1/profiles", _}] = requests()
      assert accounts_of(ctx.empty) == []
      assert ref_of(ctx.empty) == nil
    end

    test "(f) a profile-name conflict names the profile and is never adopted",
         %{conn: conn} = ctx do
      select_zernio(ctx)

      record_requests(fn conn ->
        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{
          "error" => "exists",
          "details" => %{"existingProfileId" => "zp_other"}
        })
      end)

      child = open_profile(conn, ctx.h1, ctx.empty)
      add(child, "linkedin")

      assert has_element?(
               child,
               "[data-role='social-notice']",
               "Zernio already has a profile named #{ctx.empty.name}. Rename this profile in Settings and try again."
             )

      assert accounts_of(ctx.empty) == []
      assert ref_of(ctx.empty) == nil
    end

    test "(f) a connect 403 after the profile is created: the row shows Connect, and Connect works once Zernio recovers",
         %{conn: conn} = ctx do
      select_zernio(ctx)
      ok = zernio_ok()

      record_requests(fn
        %{method: "GET"} = conn ->
          conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"error" => "forbidden"})

        conn ->
          ok.(conn)
      end)

      child = open_profile(conn, ctx.h1, ctx.empty)
      add(child, "linkedin")

      assert has_element?(
               child,
               "[data-role='social-notice']",
               "That account could not be connected. Try again."
             )

      assert [%Account{} = account] = accounts_of(ctx.empty)
      assert ref_of(ctx.empty) == "zprof_added_1"
      refute has_element?(child, "[data-pane='connections'] [data-role='social-empty']")
      assert has_element?(child, row(account) <> " " <> @connect, "Connect")
      assert [{"POST", _, _}, {"GET", _, _}] = requests()

      record_requests(ok)
      child |> element(row(account) <> " " <> @connect) |> render_click()
      assert_redirect(child, @auth_url)
      assert [{"GET", "/api/v1/connect/linkedin", %{"profileId" => "zprof_added_1"}}] = requests()
      assert [%Account{id: id}] = accounts_of(ctx.empty)
      assert id == account.id
    end

    test "Connect on a never-connected row that predates the vendor profile creates the profile first",
         %{conn: conn} = ctx do
      select_zernio(ctx)
      record_requests(zernio_ok("zprof_retry_1"))
      assert ref_of(ctx.profile) == nil

      child = open_profile(conn, ctx.h1, ctx.profile)
      child |> element(row(ctx.a) <> " " <> @connect) |> render_click()
      assert_redirect(child, @auth_url)

      assert [{"POST", "/api/v1/profiles", _}, {"GET", "/api/v1/connect/linkedin", params}] =
               requests()

      assert params["profileId"] == "zprof_retry_1"
      assert ref_of(ctx.profile) == "zprof_retry_1"
    end

    test "(g) the picker's option values are Social.connectable_platforms/0",
         %{conn: conn} = ctx do
      child = open_profile(conn, ctx.h1, ctx.empty)
      child |> element(@add) |> render_click()

      values =
        child
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#social-add-account-form select[name='platform'] option")
        |> Enum.map(&LazyHTML.attribute(&1, "value"))
        |> List.flatten()

      assert values == Social.connectable_platforms()
      assert values != []

      child |> element("[data-role='social-add-account-cancel']") |> render_click()
      refute has_element?(child, "#social-add-account-form")
      assert has_element?(child, @add)
    end

    test "the control also shows above a non-empty list; a malformed event is a no-op",
         %{conn: conn} = ctx do
      child = open_profile(conn, ctx.h1, ctx.profile)
      assert has_element?(child, @add)
      before = accounts_of(ctx.profile) |> Enum.map(& &1.id) |> Enum.sort()

      render_hook(child, "add_account", %{})
      render_hook(child, "add_account", %{"platform" => "myspace"})
      assert Process.alive?(child.pid)
      assert accounts_of(ctx.profile) |> Enum.map(& &1.id) |> Enum.sort() == before
    end
  end

  # ── Reconcile on opening Connections (task 01a14807 stage 4) ─────────

  describe "picking up connections on opening Connections" do
    @ref_a "zprof_pickup_a"
    @ref_b "zprof_pickup_b"

    setup ctx do
      select_zernio([key?: !ctx[:no_key]], ctx)

      a = linked_profile!(ctx, "Pickup A", @ref_a)
      b = linked_profile!(ctx, "Pickup B", @ref_b)
      solo = linked_profile!(ctx, "Pickup Solo", "zprof_pickup_solo")

      # Rows through the real add path; a linked profile makes no request.
      {:ok, a_li, _} = Social.add_account(ctx.org_id, a, ctx.h1.id, "linkedin")
      {:ok, a_x, _} = Social.add_account(ctx.org_id, a, ctx.h1.id, "x")
      {:ok, b_li, _} = Social.add_account(ctx.org_id, b, ctx.h1.id, "linkedin")
      {:ok, solo_li, _} = Social.add_account(ctx.org_id, solo, ctx.h1.id, "linkedin")

      %{a: a, b: b, solo: solo, a_li: a_li, a_x: a_x, b_li: b_li, solo_li: solo_li}
    end

    defp linked_profile!(ctx, name, ref) do
      {:ok, profile} =
        Social.create_profile(ctx.org_id, %{
          name: "#{name} #{unique()}",
          space_id: ctx.space.id,
          approver_user_ids: [ctx.h1.id]
        })

      profile |> Ecto.Changeset.change(provider_profile_ref: ref) |> Repo.update!()
    end

    # Lists one active linkedin account per profile ref (none for x).
    defp listing(conn) do
      ref = conn.query_params["profileId"]

      entries = [
        %{
          "_id" => "zacct_li_#{ref}",
          "platform" => "linkedin",
          "profileId" => %{"_id" => ref, "name" => "Brand"},
          "username" => "brand-#{ref}",
          "isActive" => true
        }
      ]

      Req.Test.json(conn, %{"accounts" => entries, "hasAnalyticsAccess" => false})
    end

    defp list_get(ref), do: {"GET", "/api/v1/accounts", %{"profileId" => ref}}
    defp notice?(child), do: has_element?(child, "[data-role='social-notice']")

    defp notice?(child, text),
      do: has_element?(child, "[data-role='social-notice']", text)

    defp reopen(child) do
      child |> element("[data-role='social-tab-button'][data-tab='queue']") |> render_click()

      child
      |> element("[data-role='social-tab-button'][data-tab='connections']")
      |> render_click()

      child
    end

    test "opening Connections picks up a pending row the vendor lists, with its handle",
         %{conn: conn} = ctx do
      record_requests(&listing/1)

      child = open_profile(conn, ctx.h1, ctx.a)

      assert requests() == [list_get(@ref_a)]

      assert has_element?(child, row(ctx.a_li) <> " [data-state='connected']", "Connected")

      assert has_element?(
               child,
               row(ctx.a_li) <> " [data-role='social-account-handle']",
               "brand-#{@ref_a}"
             )

      assert notice?(
               child,
               "Picked up 1 connected account from Zernio: LinkedIn brand-#{@ref_a}."
             )

      row = Repo.get!(Account, ctx.a_li.id)
      assert row.provider_account_ref == "zacct_li_#{@ref_a}"
      assert row.status == "connected"
      assert row.handle == "brand-#{@ref_a}"
    end

    test "opening it again with nothing pending makes zero requests", %{conn: conn} = ctx do
      record_requests(&listing/1)

      child = open_profile(conn, ctx.h1, ctx.solo)
      assert requests() == [list_get("zprof_pickup_solo")]
      assert has_element?(child, row(ctx.solo_li) <> " [data-state='connected']")

      reopen(child)
      assert requests() == []

      _fresh = open_profile(build_conn(), ctx.h1, ctx.solo)
      assert requests() == []
    end

    test "a pending x row the vendor does not list stays as it is, with Connect",
         %{conn: conn} = ctx do
      record_requests(&listing/1)

      child = open_profile(conn, ctx.h1, ctx.a)
      assert requests() == [list_get(@ref_a)]

      assert has_element?(child, row(ctx.a_x) <> " [data-state='none'] " <> @connect, "Connect")

      row = Repo.get!(Account, ctx.a_x.id)
      assert row.status == nil
      assert row.provider_account_ref == nil
      assert row.archived_at == nil
    end

    test "a non-approver opening Connections makes zero requests and changes no row",
         %{conn: conn} = ctx do
      record_requests(&listing/1)

      child = open_profile(conn, ctx.n, ctx.a)
      # The viewer does see the pending row, so the guard is what held.
      assert has_element?(child, row(ctx.a_li) <> " [data-state='none']")
      assert requests() == []
      refute notice?(child)

      assert Repo.get!(Account, ctx.a_li.id).status == nil

      # Positive control: the approver's identical open does reconcile.
      _child = open_profile(build_conn(), ctx.h1, ctx.a)
      assert requests() == [list_get(@ref_a)]
    end

    test "switching profile while on Connections reconciles the new profile, not the first",
         %{conn: conn} = ctx do
      record_requests(&listing/1)

      child = open_profile(conn, ctx.h1, ctx.a)
      assert requests() == [list_get(@ref_a)]

      child |> form("#social-profile-switcher", %{profile_id: ctx.b.id}) |> render_change()

      assert requests() == [list_get(@ref_b)]
      assert has_element?(child, row(ctx.b_li) <> " [data-state='connected']")

      assert notice?(
               child,
               "Picked up 1 connected account from Zernio: LinkedIn brand-#{@ref_b}."
             )

      assert Repo.get!(Account, ctx.b_li.id).provider_account_ref == "zacct_li_#{@ref_b}"
    end

    test "a vendor 503 shows the couldn't-check notice and writes nothing",
         %{conn: conn} = ctx do
      record_requests(fn conn ->
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "unavailable"})
      end)

      child = open_profile(conn, ctx.h1, ctx.a)

      assert requests() == [list_get(@ref_a)]
      assert notice?(child, "Couldn't check Zernio for connected accounts. Try again.")
      assert has_element?(child, row(ctx.a_li) <> " [data-state='none']")

      for account <- [ctx.a_li, ctx.a_x] do
        row = Repo.get!(Account, account.id)
        assert row.status == nil
        assert row.provider_account_ref == nil
      end
    end

    @tag no_key: true
    test "with no key: no request and no notice", %{conn: conn} = ctx do
      assert Platform.Social.Secrets.zernio_api_key() != {:ok, "zk-add-not-real"}
      record_requests(&listing/1)

      child = open_profile(conn, ctx.h1, ctx.a)

      assert requests() == []
      refute notice?(child)
      assert Repo.get!(Account, ctx.a_li.id).status == nil
    end
  end

  describe "Remove (task 01a14ac6 stage 3)" do
    @remove "[data-role='social-account-remove']"
    @panel "[data-role='social-remove-panel']"
    @sentence "[data-role='social-remove-sentence']"

    # d (connected, @htc_drafts): 3 cancellable posts of its own plus 1
    # shared with a post on x through one task. r (reauth): none. a: never
    # connected.
    setup ctx do
      {:ok, x} =
        Social.create_account(ctx.org_id, ctx.profile, %{
          platform: "x",
          handle: "@htc",
          status: "connected"
        })

      task = task!(ctx.org_id)
      d_posts = for _ <- 1..3, do: remove_post!(ctx, ctx.d)
      shared = remove_post!(ctx, ctx.d, %{task_id: task.id})
      _sibling = remove_post!(ctx, x, %{task_id: task.id})
      Fake.reset()

      %{x: x, d_posts: [shared | d_posts]}
    end

    defp remove_post!(ctx, account, attrs \\ %{}) do
      {:ok, post} =
        Social.create_post(
          ctx.org_id,
          account,
          Map.merge(%{body: "Episode 12", status: "needs_approval"}, attrs)
        )

      post
    end

    defp post_states(posts),
      do: Enum.map(posts, &Repo.get!(Platform.Social.Post, &1.id)) |> Enum.map(& &1.status)

    defp open_panel(child, account),
      do: child |> element(row(account) <> " " <> @remove) |> render_click()

    test "(a) an approver sees Remove on every row; a non-approver and an agent see none",
         %{conn: conn} = ctx do
      child = open(conn, ctx.h1)

      for account <- [ctx.a, ctx.d, ctx.r, ctx.x] do
        assert has_element?(child, row(account) <> " button" <> @remove, "Remove")
      end

      refute has_element?(child, @remove <> ".btn-error")
      refute has_element?(child, @remove <> ".btn-primary")

      n_child = open(build_conn(), ctx.n)
      assert has_element?(n_child, row(ctx.d))
      refute has_element?(n_child, @remove)

      {:ok, g_view, _html} =
        live_isolated(build_conn(), PlatformWeb.SocialLive, session: %{"user_id" => ctx.g.id})

      refute has_element?(g_view, @remove)
    end

    test "(b) forged open_remove and remove_account from a non-approver or an agent change nothing",
         %{conn: conn} = ctx do
      before = post_states(ctx.d_posts)
      n_child = open(conn, ctx.n)

      render_hook(n_child, "open_remove", %{"id" => ctx.d.id})
      refute has_element?(n_child, @panel)
      render_hook(n_child, "remove_account", %{"id" => ctx.d.id})

      assert has_element?(
               n_child,
               "[data-role='social-notice']",
               "Only an approver of this profile can change it."
             )

      assert has_element?(n_child, row(ctx.d))

      {:ok, g_view, _html} =
        live_isolated(build_conn(), PlatformWeb.SocialLive, session: %{"user_id" => ctx.g.id})

      render_hook(g_view, "open_remove", %{"id" => ctx.d.id})
      render_hook(g_view, "remove_account", %{"id" => ctx.d.id})
      assert Process.alive?(g_view.pid)

      assert Repo.get!(Account, ctx.d.id).archived_at == nil
      assert post_states(ctx.d_posts) == before
      assert Fake.calls() == []
    end

    test "(c) the panel shows the real counts, the zero sentence and the never-connected sentence; one panel at a time",
         %{conn: conn} = ctx do
      child = open(conn, ctx.h1)
      refute has_element?(child, @panel)

      open_panel(child, ctx.d)

      assert has_element?(
               child,
               row(ctx.d) <> " " <> @sentence,
               "Remove LINKEDIN @htc_drafts? 3 scheduled posts will be cancelled, and 1 shared post will stop posting here. Past posts stay in history."
             )

      assert has_element?(child, row(ctx.d) <> " " <> @sentence <> " .font-semibold", "3")

      assert has_element?(
               child,
               row(ctx.d) <> " " <> @sentence <> " .font-mono",
               "LINKEDIN @htc_drafts"
             )

      assert has_element?(
               child,
               row(ctx.d) <> " [data-role='social-remove-reconnect']",
               "You can reconnect this account later."
             )

      assert has_element?(
               child,
               row(ctx.d) <> " [data-role='social-remove-cancel'][phx-mounted*='focus']",
               "Cancel"
             )

      assert has_element?(
               child,
               row(ctx.d) <>
                 " button.btn-error[data-role='social-remove-confirm'][phx-disable-with='Removing...']",
               "Remove account"
             )

      # Opening another row's panel closes the first.
      open_panel(child, ctx.r)
      refute has_element?(child, row(ctx.d) <> " " <> @panel)

      assert has_element?(
               child,
               row(ctx.r) <> " " <> @sentence,
               "Remove YOUTUBE HTC channel? No scheduled posts are affected."
             )

      open_panel(child, ctx.x)
      refute has_element?(child, row(ctx.r) <> " " <> @panel)

      assert has_element?(
               child,
               row(ctx.x) <> " " <> @sentence,
               "Remove X @htc? 1 shared post will stop posting here. Past posts stay in history."
             )

      open_panel(child, ctx.a)

      assert [_one] =
               child
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query(@panel)
               |> Enum.to_list()

      assert has_element?(
               child,
               row(ctx.a) <> " " <> @sentence,
               "Remove LINKEDIN @htc_official? It was never connected, so nothing else changes."
             )

      refute has_element?(child, row(ctx.a) <> " [data-role='social-remove-reconnect']")

      child |> element(row(ctx.a) <> " [data-role='social-remove-cancel']") |> render_click()
      refute has_element?(child, @panel)
      assert has_element?(child, row(ctx.a))
    end

    test "(d) confirm removes the row with the success notice", %{conn: conn} = ctx do
      child = open(conn, ctx.h1)
      open_panel(child, ctx.d)
      child |> element(row(ctx.d) <> " [data-role='social-remove-confirm']") |> render_click()

      refute has_element?(child, row(ctx.d))
      assert has_element?(child, row(ctx.a))

      assert has_element?(
               child,
               "[data-role='social-notice'][data-tone='info']",
               "Removed LINKEDIN @htc_drafts."
             )

      refute has_element?(child, ".alert-warning[data-role='social-notice']")
      refute has_element?(child, @panel)
      assert %DateTime{} = Repo.get!(Account, ctx.d.id).archived_at
    end

    test "(d) an unconfirmed vendor disconnect removes the row with the warning notice",
         %{conn: conn} = ctx do
      ctx.d |> Ecto.Changeset.change(provider_account_ref: "zacct_d") |> Repo.update!()
      Fake.fail_next(:disconnect_account, :x)

      child = open(conn, ctx.h1)
      open_panel(child, ctx.d)
      child |> element(row(ctx.d) <> " [data-role='social-remove-confirm']") |> render_click()

      refute has_element?(child, row(ctx.d))

      assert has_element?(
               child,
               ".alert.alert-warning[data-role='social-notice']",
               "Removed here. Zernio didn't confirm the disconnect, so check the account in Zernio."
             )

      assert [{:disconnect_account, _, _}] = Fake.calls(:disconnect_account)
      assert %DateTime{} = Repo.get!(Account, ctx.d.id).archived_at
    end

    test "removing the only account shows the empty state; a vanished row says it is gone",
         %{conn: conn} = ctx do
      child = open(conn, ctx.h1)
      open_panel(child, ctx.a)

      {:ok, _, _} = Social.remove_account(ctx.org_id, ctx.profile, ctx.h2.id, ctx.a.id)
      child |> element(row(ctx.a) <> " [data-role='social-remove-confirm']") |> render_click()

      assert has_element?(child, "[data-role='social-notice']", "That account is already gone.")
      refute has_element?(child, row(ctx.a))

      for account <- [ctx.d, ctx.r, ctx.x] do
        open_panel(child, account)
        child |> element(row(account) <> " [data-role='social-remove-confirm']") |> render_click()
      end

      assert has_element?(child, "[data-role='social-empty']")
    end

    test "(e) the Remove copy never says Delete", %{conn: conn} = ctx do
      child = open(conn, ctx.h1)
      open_panel(child, ctx.d)

      text =
        child
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#social-accounts")
        |> LazyHTML.text()

      assert text =~ "Remove account"
      assert text =~ "Cancel"
      refute text =~ ~r/delete/i
    end
  end
end
