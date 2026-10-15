defmodule PlatformWeb.AdminSignInUsersLiveTest do
  @moduledoc """
  Task 01a113ea stage 3: `/admin/sign-in-users`, the UI over
  `Platform.SignInAdmin`.

  pocket-id is a small stateful fake behind the `Req.Test` stub named
  `Platform.SignInAdmin.PocketId` (the same shapes stage 2's context test
  uses). Every request the stub sees is sent to the test process, so "zero
  requests" is an assertion and not an assumption.

  The guards proven here, each with the mutation that detonates it:

    * gate off -> 404 for an admin, a non-admin and a signed-out caller, and
      `/admin` names neither the route nor pocket-id (M-gate-web: plug no-op
      and mount raise dropped);
    * an admin demoted while the page is open is refused on every event by
      the LiveView itself, with a flash and a navigation the context never
      produces (M-authz-web: `guard/1` removed from `handle_event/3`);
    * the minted link never reaches the log, and leaves the page on Done.
  """
  # async: false: flips :platform app env (the gate, URL, key) and, in one
  # test, the global Logger level.
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Platform.Accounts
  alias Platform.Repo
  alias Platform.SignInAdmin.PocketId
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  @path "/admin/sign-in-users"
  @key "pid-web-key-0123456789-SECRET"
  @token "TOKENa1b2c3Z"
  @static "00000000-0000-0000-0000-000000000000"
  @env_keys [:sign_in_admin_enabled, :sign_in_admin_url, :sign_in_admin_api_key]

  setup %{conn: conn} do
    saved = for key <- @env_keys, do: {key, Application.fetch_env(:platform, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    Application.put_env(:platform, :sign_in_admin_url, "http://pocket-id.test")
    Application.put_env(:platform, :sign_in_admin_api_key, @key)
    gate(true)

    admin = suite_user!("admin")
    {:ok, _} = Tenancy.promote_to_admin(admin)
    assert Tenancy.root_admin?(admin)

    %{conn: conn, admin: admin}
  end

  # -- fixtures -------------------------------------------------------------

  defp gate(on?), do: Application.put_env(:platform, :sign_in_admin_enabled, on?)

  defp suite_user!(label) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.find_or_create_from_oidc(%{
        sub: "sub-#{label}-#{n}",
        email: "#{label}-#{n}@example.test",
        name: "#{String.capitalize(label)} #{n}"
      })

    user
  end

  defp login(conn, user), do: Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})

  defp demote!(user) do
    root = Tenancy.get_root_org()

    {n, _} =
      Repo.delete_all(
        from(m in OrgMembership, where: m.user_id == ^user.id and m.org_id == ^root.id)
      )

    assert n >= 1
    refute Tenancy.root_admin?(user)
  end

  defp pid_user(id, email, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "username" => "u-#{id}",
        "email" => email,
        "emailVerified" => true,
        "firstName" => "First",
        "lastName" => "Last",
        "displayName" => "First Last",
        "isAdmin" => false,
        "locale" => "en",
        "disabled" => false
      },
      overrides
    )
  end

  # -- fake pocket-id -------------------------------------------------------

  defp fake!(opts) do
    test = self()

    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             users: Map.new(Keyword.get(opts, :users, []), &{&1["id"], &1}),
             passkeys: Keyword.get(opts, :passkeys, %{}),
             fail: Keyword.get(opts, :fail, %{})
           }
         end}
      )

    Req.Test.stub(PocketId, fn conn -> handle(conn, agent, test) end)
    agent
  end

  defp handle(conn, agent, test) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    conn = Plug.Conn.fetch_query_params(conn)
    body = if raw == "", do: nil, else: Jason.decode!(raw)
    kind = kind(conn.method, conn.path_info)
    send(test, {:pocket_id_req, %{method: conn.method, path: conn.request_path, kind: kind}})

    case Agent.get(agent, &get_in(&1, [:fail, kind])) do
      nil -> route(kind, conn, body, agent)
      status -> json(conn, status, %{"error" => "stub failure"})
    end
  end

  defp kind("GET", ["api", "users"]), do: :list
  defp kind("POST", ["api", "users"]), do: :create
  defp kind("GET", ["api", "users", _]), do: :get
  defp kind("PUT", ["api", "users", _]), do: :put
  defp kind("DELETE", ["api", "users", _]), do: :delete
  defp kind("GET", ["api", "users", _, "webauthn-credentials"]), do: :passkeys
  defp kind("POST", ["api", "users", _, "one-time-access-token"]), do: :token

  defp route(:list, conn, _body, agent) do
    search = conn.query_params["search"]

    users =
      agent
      |> Agent.get(& &1.users)
      |> Map.values()
      |> Enum.filter(&(is_nil(search) or String.contains?(String.downcase(&1["email"]), search)))

    json(conn, 200, %{
      "data" => [pid_user(@static, "static-api-user@pocket-id.invalid") | users],
      "pagination" => %{"totalPages" => 1, "currentPage" => 1, "itemsPerPage" => 100}
    })
  end

  defp route(:create, conn, body, agent) do
    id = "pid-#{System.unique_integer([:positive])}"
    user = Map.merge(body, %{"id" => id, "disabled" => false, "locale" => nil})
    Agent.update(agent, &put_in(&1, [:users, id], user))
    json(conn, 201, user)
  end

  defp route(:get, conn, _body, agent) do
    case Agent.get(agent, &Map.get(&1.users, id_of(conn))) do
      nil -> json(conn, 404, %{"error" => "not found"})
      user -> json(conn, 200, user)
    end
  end

  defp route(:put, conn, body, agent) do
    id = id_of(conn)

    updated =
      Agent.get_and_update(agent, fn state ->
        case Map.get(state.users, id) do
          nil ->
            {nil, state}

          user ->
            merged = Map.merge(user, body)
            {merged, put_in(state, [:users, id], merged)}
        end
      end)

    if updated, do: json(conn, 200, updated), else: json(conn, 404, %{"error" => "not found"})
  end

  defp route(:delete, conn, _body, agent) do
    id = id_of(conn)

    existed =
      Agent.get_and_update(agent, fn state ->
        {Map.has_key?(state.users, id), %{state | users: Map.delete(state.users, id)}}
      end)

    if existed,
      do: Plug.Conn.send_resp(conn, 204, ""),
      else: json(conn, 404, %{"error" => "not found"})
  end

  defp route(:passkeys, conn, _body, agent) do
    n = Agent.get(agent, &Map.get(&1.passkeys, Enum.at(conn.path_info, 2), 0))
    json(conn, 200, for(i <- 1..n//1, do: %{"id" => "cred-#{i}"}))
  end

  defp route(:token, conn, _body, agent) do
    if Agent.get(agent, &Map.has_key?(&1.users, Enum.at(conn.path_info, 2))),
      do: json(conn, 201, %{"token" => @token}),
      else: json(conn, 404, %{"error" => "not found"})
  end

  defp id_of(conn), do: Enum.at(conn.path_info, 2)

  defp json(conn, status, body),
    do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

  defp requests(acc \\ []) do
    receive do
      {:pocket_id_req, req} -> requests([req | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # A mounted page with the pocket-id load finished and the mailbox drained.
  defp mount!(conn, user) do
    {:ok, view, _html} = live(login(conn, user), @path)
    _ = render_async(view)
    _ = requests()
    view
  end

  # The admin plus three people, one per status the page colours: pending
  # (no passkey), active (a passkey), disabled.
  defp people!(admin) do
    pending = suite_user!("pending")
    active = suite_user!("active")
    disabled = suite_user!("disabled")

    agent =
      fake!(
        users: [
          pid_user(admin.oidc_sub, admin.email),
          pid_user(pending.oidc_sub, pending.email),
          pid_user(active.oidc_sub, active.email),
          pid_user(disabled.oidc_sub, disabled.email, %{"disabled" => true})
        ],
        passkeys: %{admin.oidc_sub => 1, active.oidc_sub => 2}
      )

    %{pending: pending, active: active, disabled: disabled, agent: agent}
  end

  # -- gate -----------------------------------------------------------------

  describe "gate off" do
    setup %{admin: admin} do
      member = suite_user!("member")
      refute Tenancy.root_admin?(member)
      gate(false)
      %{member: member, admin: admin}
    end

    test "/admin/sign-in-users is 404 for an admin", %{conn: conn, admin: admin} do
      assert_error_sent(404, fn -> get(login(conn, admin), @path) end)
    end

    test "/admin/sign-in-users is 404 for a non-admin (not a redirect)", %{
      conn: conn,
      member: member
    } do
      assert_error_sent(404, fn -> get(login(conn, member), @path) end)
    end

    test "/admin/sign-in-users is 404 signed out (not a login redirect)", %{conn: conn} do
      assert_error_sent(404, fn -> get(conn, @path) end)
    end

    test "/admin names neither the route nor pocket-id", %{conn: conn, admin: admin} do
      html = conn |> login(admin) |> get("/admin") |> html_response(200)
      # The page did render: the neighbouring tile is there.
      assert html =~ ~s(data-role="admin-orgs-link")
      refute html =~ "admin-sign-in-users-link"
      refute html =~ "sign-in-users"
      refute html =~ ~r/pocket/i
    end

    test "fail closed: \"1\" is not \"true\"", %{conn: conn, admin: admin} do
      Application.delete_env(:platform, :sign_in_admin_enabled)
      System.put_env("POCKET_ID_ADMIN_ENABLED", "1")
      on_exit(fn -> System.delete_env("POCKET_ID_ADMIN_ENABLED") end)

      assert_error_sent(404, fn -> get(login(conn, admin), @path) end)
    end
  end

  describe "gate on (positive control for the 404s)" do
    test "admin gets 200 and /admin shows the tile", %{conn: conn, admin: admin} do
      fake!(users: [pid_user(admin.oidc_sub, admin.email)], passkeys: %{admin.oidc_sub => 1})

      html = conn |> login(admin) |> get(@path) |> html_response(200)
      assert html =~ "Admin · Users"

      admin_html = conn |> login(admin) |> get("/admin") |> html_response(200)
      assert admin_html =~ ~s(data-role="admin-sign-in-users-link")
      assert admin_html =~ ~s(href="/admin/sign-in-users")
    end

    test "signed out is sent to login, a non-admin is sent away", %{conn: conn} do
      assert redirected_to(get(conn, @path)) =~ "/auth/login"

      member = suite_user!("member")

      assert {:error, {_, %{to: "/access-denied?module=admin"}}} =
               live(login(conn, member), @path)

    end

    test "a websocket mount after the switch went off raises the 404 in mount/3",
         %{conn: conn, admin: admin} do
      fake!(users: [pid_user(admin.oidc_sub, admin.email)], passkeys: %{admin.oidc_sub => 1})
      conn = conn |> login(admin) |> get(@path)
      assert html_response(conn, 200) =~ "Admin · Users"

      gate(false)

      # The connected mount raised `RequireSignInAdmin.NotFoundError`, whose
      # `plug_status` the client receives as a 404 reload.
      assert {%{status: 404, reason: "reload"}, _} = catch_exit(live(conn))
    end
  end

  # -- page -----------------------------------------------------------------

  describe "list" do
    test "renders Pending, Disabled and Active, Pending first", %{conn: conn, admin: admin} do
      %{pending: pending, active: active, disabled: disabled} = people!(admin)
      view = mount!(conn, admin)
      html = render(view)

      assert has_element?(view, "#table-user-#{pending.id} [data-role=status-pending]")
      assert has_element?(view, "#table-user-#{disabled.id} [data-role=status-disabled]")
      assert has_element?(view, "#table-user-#{active.id} [data-role=status-active]")
      # The static API user is never listed.
      refute html =~ @static

      ids =
        Regex.scan(~r/id="table-user-([^"]+)"/, html, capture: :all_but_first)
        |> List.flatten()

      assert Enum.take(ids, 2) == [pending.id, disabled.id]

      # Disabled shows Enable instead of Disable; own row is disabled with a reason.
      assert has_element?(view, "#table-user-#{disabled.id} [data-role=enable]")
      refute has_element?(view, "#table-user-#{disabled.id} [data-role=disable]")

      assert has_element?(
               view,
               ~s(#table-user-#{admin.id} button[data-role=disable][disabled][title="You can't disable or remove yourself"])
             )
    end

    test "search filters name and email", %{conn: conn, admin: admin} do
      %{pending: pending, active: active} = people!(admin)
      view = mount!(conn, admin)

      view |> element("[data-role=search-form]") |> render_change(%{"q" => pending.email})
      assert has_element?(view, "#table-user-#{pending.id}")
      refute has_element?(view, "#table-user-#{active.id}")

      view |> element("[data-role=search-form]") |> render_change(%{"q" => "zzz-nobody"})
      assert render(view) =~ "No one matches"
    end

    test "unreachable: alert, and no Invite / Send link / Disable / Enable / Remove",
         %{conn: conn, admin: admin} do
      people!(admin)
      Req.Test.stub(PocketId, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      {:ok, view, _html} = live(login(conn, admin), @path)
      html = render_async(view)

      assert html =~ "Can&#39;t reach the sign-in service."
      assert has_element?(view, "[data-role=retry]")

      for role <- ~w(open-invite resend-link disable enable open-remove pocket-id-admin-link) do
        refute has_element?(view, "[data-role=#{role}]"), "#{role} rendered while unreachable"
      end
    end
  end

  describe "invite and the credential slip" do
    test "shows the slip once, never logs the link, and Done takes it off the page",
         %{conn: conn, admin: admin} do
      fake!(users: [pid_user(admin.oidc_sub, admin.email)], passkeys: %{admin.oidc_sub => 1})
      view = mount!(conn, admin)

      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        capture_log([level: :debug], fn ->
          view |> element("[data-role=open-invite]") |> render_click()

          view
          |> form("#invite-user-form", %{
            "invite" => %{
              "email" => "dana@example.test",
              "name" => "Dana Lee",
              "role" => "member"
            }
          })
          |> render_submit()

          Logger.flush()
        end)

      # Positive control: the context's id-only line IS captured.
      assert log =~ "sign_in_admin.invite suite_user_id="
      refute log =~ @token
      refute log =~ "/lc/"
      refute log =~ @key

      html = render(view)
      assert html =~ "Sign-in link for Dana Lee"
      assert html =~ "Shown once."
      assert html =~ "TOKE Na1b 2c3Z"
      assert html =~ "/lc/#{@token}"
      assert html =~ "Expires at"

      view |> element("[data-role=slip-done]") |> render_click()
      html = render_async(view)
      refute html =~ @token
      refute html =~ "TOKE Na1b 2c3Z"

      dana = Enum.find(Accounts.list_users(), &(&1.email == "dana@example.test"))
      assert dana
      assert has_element?(view, "#table-user-#{dana.id} [data-role=link-expiry]")
      assert render(view) =~ "Link expires"

      # Nothing persisted the token.
      refute Repo.exists?(from(u in Accounts.User, where: like(u.name, ^"%#{@token}%")))
    end

    test "duplicate email shows Saru's inline copy", %{conn: conn, admin: admin} do
      fake!(users: [pid_user(admin.oidc_sub, admin.email)], passkeys: %{admin.oidc_sub => 1})
      view = mount!(conn, admin)
      view |> element("[data-role=open-invite]") |> render_click()

      html =
        view
        |> form("#invite-user-form", %{
          "invite" => %{"email" => admin.email, "name" => "", "role" => "member"}
        })
        |> render_submit()

      assert html =~ "#{admin.name} already has access with this email."
      assert html =~ "Show in list"
    end

    test "the slip swaps in the expired copy when its timer fires", %{conn: conn, admin: admin} do
      %{pending: pending} = people!(admin)
      view = mount!(conn, admin)
      view |> element("#table-user-#{pending.id} [data-role=resend-link]") |> render_click()
      assert render(view) =~ "/lc/#{@token}"

      %{slip: %{ref: ref}} = :sys.get_state(view.pid).socket.assigns
      send(view.pid, {:slip_expired, ref})

      html = render(view)
      assert html =~ "This link expired at"
      refute html =~ @token
    end
  end

  describe "disable, undo, remove" do
    test "disable flips the row and offers Undo, which enables again",
         %{conn: conn, admin: admin} do
      %{active: active} = people!(admin)
      view = mount!(conn, admin)

      view |> element("#table-user-#{active.id} [data-role=disable]") |> render_click()
      assert render(view) =~ "is disabled and can&#39;t sign in."
      assert Accounts.get_user(active.id).archived_at

      view |> element("[data-role=undo-disable]") |> render_click()
      assert render(view) =~ "can sign in again."
      refute Accounts.get_user(active.id).archived_at
    end

    test "Undo still enables a user who holds a live Suite-minted link (01a114c1)",
         %{conn: conn, admin: admin} do
      %{active: active} = people!(admin)

      {1, _} =
        Repo.update_all(from(u in Accounts.User, where: u.id == ^active.id),
          set: [sign_in_link_expires_at: ~U[2099-01-01 14:37:00Z]]
        )

      view = mount!(conn, admin)
      view |> element("#table-user-#{active.id} [data-role=disable]") |> render_click()
      assert Accounts.get_user(active.id).archived_at

      view |> element("[data-role=undo-disable]") |> render_click()
      assert render(view) =~ "can sign in again."
      refute Accounts.get_user(active.id).archived_at
    end

    test "Enable on a row with a live Suite-minted link shows when it can be enabled (01a114c1)",
         %{conn: conn, admin: admin} do
      %{disabled: disabled} = people!(admin)

      {1, _} =
        Repo.update_all(from(u in Accounts.User, where: u.id == ^disabled.id),
          set: [sign_in_link_expires_at: ~U[2099-01-01 14:37:00Z]]
        )

      view = mount!(conn, admin)
      view |> element("#table-user-#{disabled.id} [data-role=enable]") |> render_click()

      assert render(view) =~
               "A sign-in link sent before #{disabled.name} was disabled is valid until 14:37 UTC. Enable them after that."

      assert Enum.filter(requests(), &(&1.kind == :put)) == []
      assert has_element?(view, "#table-user-#{disabled.id} [data-role=enable]")
    end

    test "remove asks with the soft copy and keeps the Suite row", %{conn: conn, admin: admin} do
      %{pending: pending} = people!(admin)
      view = mount!(conn, admin)

      view |> element("#table-user-#{pending.id} [data-role=open-remove]") |> render_click()
      html = render(view)
      assert html =~ "Remove #{pending.name}?"
      assert html =~ "Their messages, tasks and files stay in Suite under their name."
      refute html =~ "Type"

      view |> element("[data-role=confirm-remove]") |> render_click()
      assert %{archived_at: %DateTime{}} = Accounts.get_user(pending.id)
    end
  end

  # -- admin on every event (layer 1) ---------------------------------------

  describe "an admin demoted while the page is open" do
    # Each event navigates away, so each gets its own fresh mount.
    @events [
      {"invite",
       %{"invite" => %{"email" => "forged@example.test", "name" => "F", "role" => "admin"}}},
      {"resend_link", :target},
      {"disable", :target},
      {"enable", :target},
      {"open_remove", :target},
      {"remove", :target},
      {"retry", %{}}
    ]

    for {event, params} <- @events do
      test "is refused by the LiveView on #{event}, before any pocket-id request",
           %{conn: conn, admin: admin} do
        %{active: target} = people!(admin)
        view = mount!(conn, admin)
        demote!(admin)

        params =
          case unquote(Macro.escape(params)) do
            :target -> %{"id" => target.id}
            map -> map
          end

        assert {:error, {:live_redirect, %{to: "/"}}} =
                 render_click(view, unquote(event), params)

        flash = assert_redirect(view, "/")
        assert Phoenix.Flash.get(flash, :error) == "You don't have access to that page."
        assert requests() == []
        refute Accounts.get_user(target.id).archived_at
        refute Enum.any?(Accounts.list_users(), &(&1.email == "forged@example.test"))
      end
    end
  end
end
