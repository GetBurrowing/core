defmodule Platform.SignInAdmin.PocketIdTest do
  @moduledoc """
  Task 01a113ea stage 1: the pocket-id admin client. Every request goes to
  the `Req.Test` stub named `Platform.SignInAdmin.PocketId`
  (`config/test.exs`). Response shapes mirror what pocket-id v2.18.0 returned
  live on moon during this stage (create 201, duplicate username/email 409
  with `details.property`, one-time token 201 `{"token": ...}`, delete 204,
  missing user 404).
  """
  # async: false: swaps :platform app env and the global Logger level.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Platform.SignInAdmin.Config
  alias Platform.SignInAdmin.PocketId
  alias Platform.SignInAdmin.PocketId.{Token, User}

  @key "pid-test-key-0123456789-SECRET"
  @token "TOKENa1b2c3Z"
  @static "00000000-0000-0000-0000-000000000000"

  setup do
    saved =
      for key <- [:sign_in_admin_url, :sign_in_admin_api_key],
          do: {key, Application.fetch_env(:platform, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    Application.put_env(:platform, :sign_in_admin_url, "http://pocket-id.test/")
    Application.put_env(:platform, :sign_in_admin_api_key, @key)
    :ok
  end

  # -- stub helpers ---------------------------------------------------------

  # Records every request to the test process, then answers with `responder`.
  # Assertions live in the test, not in the stub: an assert raised inside the
  # plug would surface as a transport error and hide the real failure.
  defp stub(responder) do
    pid = self()

    Req.Test.stub(PocketId, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      conn = Plug.Conn.fetch_query_params(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)

      send(pid, {
        :pocket_id_req,
        %{
          method: conn.method,
          path: conn.request_path,
          query: conn.query_params,
          key: Plug.Conn.get_req_header(conn, "x-api-key"),
          host: conn.host,
          body: body
        }
      })

      responder.(conn, body)
    end)
  end

  defp requests(acc \\ []) do
    receive do
      {:pocket_id_req, req} -> requests([req | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_every_request_keyed(reqs) do
    assert reqs != [], "expected at least one request"

    for req <- reqs do
      assert req.key == [@key], "#{req.method} #{req.path} sent no x-api-key"
      assert req.host == "pocket-id.test"
    end

    reqs
  end

  defp json(conn, status, body),
    do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

  defp user_json(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "username" => "u-#{id}",
        "email" => "#{id}@example.test",
        "emailVerified" => true,
        "firstName" => "First",
        "lastName" => "Last",
        "displayName" => "First Last",
        "isAdmin" => false,
        "locale" => "en",
        "customClaims" => [],
        "userGroups" => [],
        "ldapId" => nil,
        "disabled" => false
      },
      overrides
    )
  end

  defp page(users, current, total) do
    %{
      "data" => users,
      "pagination" => %{
        "totalPages" => total,
        "totalItems" => length(users),
        "currentPage" => current,
        "itemsPerPage" => 100
      }
    }
  end

  # -- list / find ----------------------------------------------------------

  describe "list_users/0" do
    test "fetches every page with limit 100 and drops the static API user" do
      stub(fn conn, _ ->
        case conn.query_params["pagination"]["page"] do
          "1" -> json(conn, 200, page([user_json(@static), user_json("a")], 1, 2))
          "2" -> json(conn, 200, page([user_json("b")], 2, 2))
        end
      end)

      assert {:ok, users} = PocketId.list_users()
      assert Enum.map(users, & &1.id) == ["a", "b"]
      assert [%User{id: "a", email: "a@example.test", disabled: false, locale: "en"} | _] = users

      reqs = requests() |> assert_every_request_keyed()
      assert Enum.map(reqs, & &1.path) == ["/api/users", "/api/users"]

      assert Enum.map(reqs, & &1.query["pagination"]) == [
               %{"limit" => "100", "page" => "1"},
               %{"limit" => "100", "page" => "2"}
             ]
    end

    test "a non-2xx status is {:http, status}; a malformed body is :bad_response" do
      stub(fn conn, _ -> json(conn, 503, %{"error" => "down"}) end)
      assert PocketId.list_users() == {:error, {:http, 503}}

      stub(fn conn, _ -> json(conn, 200, %{"unexpected" => true}) end)
      assert PocketId.list_users() == {:error, :bad_response}
    end
  end

  describe "find_by_email/1" do
    test "searches by the normalized email and returns only an exact match" do
      stub(fn conn, _ ->
        json(
          conn,
          200,
          page(
            [
              user_json("near", %{"email" => "xalice@example.test"}),
              user_json("hit", %{"email" => "Alice@Example.test"})
            ],
            1,
            1
          )
        )
      end)

      assert {:ok, %User{id: "hit"}} = PocketId.find_by_email("  ALICE@example.TEST ")
      assert [req] = requests() |> assert_every_request_keyed()
      assert req.query["search"] == "alice@example.test"
    end

    test "returns {:ok, nil} when no user has that email" do
      stub(fn conn, _ -> json(conn, 200, page([user_json(@static, %{"email" => nil})], 1, 1)) end)
      assert PocketId.find_by_email("nobody@example.test") == {:ok, nil}
    end
  end

  # -- create ---------------------------------------------------------------

  describe "create_user/1" do
    test "creates a non-admin, email-verified user with an installer-style username" do
      stub(fn conn, body ->
        json(conn, 201, user_json("new", %{"username" => body["username"]}))
      end)

      assert {:ok, %User{id: "new", username: "alice.smithx"}} =
               PocketId.create_user(%{email: " Alice.Smith+x@Example.TEST ", name: "Alice Smith"})

      assert [req] = requests() |> assert_every_request_keyed()
      assert req.method == "POST"
      assert req.path == "/api/users"

      assert req.body == %{
               "username" => "alice.smithx",
               "email" => "alice.smith+x@example.test",
               "emailVerified" => true,
               "firstName" => "Alice",
               "lastName" => "Smith",
               "displayName" => "Alice Smith",
               "isAdmin" => false
             }
    end

    test "the name falls back to the email's local part" do
      stub(fn conn, _ -> json(conn, 201, user_json("new")) end)
      assert {:ok, _} = PocketId.create_user(%{email: "bob@example.test", name: "  "})
      assert [%{body: %{"displayName" => "bob", "firstName" => "bob"}}] = requests()
    end

    test "a duplicate username retries with a numeric suffix" do
      stub(fn conn, body ->
        case body["username"] do
          name when name in ["alice", "alice2"] ->
            json(conn, 409, %{
              "error" => "Username is already in use",
              "code" => "already_in_use",
              "details" => %{"property" => "username"}
            })

          name ->
            json(conn, 201, user_json("new", %{"username" => name}))
        end
      end)

      assert {:ok, %User{username: "alice3"}} =
               PocketId.create_user(%{email: "alice@example.test"})

      assert Enum.map(requests(), & &1.body["username"]) == ["alice", "alice2", "alice3"]
    end

    test "a duplicate email is :email_taken, and an email with no usable local part gets \"user\"" do
      stub(fn conn, _ ->
        json(conn, 409, %{
          "error" => "Email is already in use",
          "code" => "already_in_use",
          "details" => %{"property" => "email"}
        })
      end)

      assert PocketId.create_user(%{email: "+++@example.test"}) == {:error, :email_taken}
      assert [%{body: %{"username" => "user"}}] = requests()
    end
  end

  # -- per-user calls -------------------------------------------------------

  describe "passkey_count/1" do
    test "counts the user's WebAuthn credentials" do
      stub(fn conn, _ -> json(conn, 200, [%{"id" => "c1"}, %{"id" => "c2"}]) end)
      assert PocketId.passkey_count("u1") == {:ok, 2}

      assert [%{method: "GET", path: "/api/users/u1/webauthn-credentials"}] =
               requests() |> assert_every_request_keyed()
    end
  end

  describe "one_time_token/1" do
    test "asks for a 30m TTL (a 12-character code) and returns the token redacted" do
      stub(fn conn, _ -> json(conn, 201, %{"token" => @token}) end)

      assert {:ok, %Token{value: @token} = token} = PocketId.one_time_token("u1")
      assert inspect(token) == "#SignInAdmin.Token<redacted>"

      assert [req] = requests() |> assert_every_request_keyed()
      assert req.method == "POST"
      assert req.path == "/api/users/u1/one-time-access-token"
      assert req.body == %{"ttl" => "30m"}
    end
  end

  describe "set_disabled/2" do
    test "reads the user, then PUTs the full DTO back with only `disabled` changed" do
      current =
        user_json("u1", %{
          "username" => "carol",
          "email" => "carol@example.test",
          "firstName" => "Carol",
          "lastName" => "Jones",
          "displayName" => "CJ",
          "locale" => "de"
        })

      stub(fn conn, body ->
        case conn.method do
          "GET" -> json(conn, 200, current)
          "PUT" -> json(conn, 200, Map.merge(current, body))
        end
      end)

      assert {:ok, %User{id: "u1", disabled: true}} = PocketId.set_disabled("u1", true)

      assert [get, put] = requests() |> assert_every_request_keyed()
      assert {get.method, get.path} == {"GET", "/api/users/u1"}
      assert {put.method, put.path} == {"PUT", "/api/users/u1"}

      assert put.body == %{
               "username" => "carol",
               "email" => "carol@example.test",
               "emailVerified" => true,
               "firstName" => "Carol",
               "lastName" => "Jones",
               "displayName" => "CJ",
               "isAdmin" => false,
               "locale" => "de",
               "disabled" => true
             }
    end

    test "a missing user is :not_found and no PUT is sent" do
      stub(fn conn, _ -> json(conn, 404, %{"error" => "User not found"}) end)
      assert PocketId.set_disabled("gone", false) == {:error, :not_found}
      assert [%{method: "GET"}] = requests()
    end
  end

  describe "delete_user/1" do
    test "204 is :ok, 404 is :not_found" do
      stub(fn conn, _ -> Plug.Conn.send_resp(conn, 204, "") end)
      assert PocketId.delete_user("u1") == :ok

      assert [%{method: "DELETE", path: "/api/users/u1"}] =
               requests() |> assert_every_request_keyed()

      stub(fn conn, _ -> json(conn, 404, %{"error" => "User not found"}) end)
      assert PocketId.delete_user("u1") == {:error, :not_found}
    end

    test "an id is path-encoded, never interpolated raw" do
      stub(fn conn, _ -> Plug.Conn.send_resp(conn, 204, "") end)
      assert PocketId.delete_user("../admin") == :ok
      assert [%{path: path}] = requests()
      refute path =~ "/../"
    end
  end

  describe "transport and configuration errors" do
    test "a transport error is :transport" do
      stub(fn conn, _ -> Req.Test.transport_error(conn, :econnrefused) end)
      assert PocketId.list_users() == {:error, :transport}
      assert PocketId.delete_user("u1") == {:error, :transport}
    end

    test "with no URL or key nothing is sent and the result is :not_configured" do
      stub(fn conn, _ -> json(conn, 200, page([], 1, 1)) end)

      Application.put_env(:platform, :sign_in_admin_api_key, "")
      assert PocketId.list_users() == {:error, :not_configured}

      Application.put_env(:platform, :sign_in_admin_api_key, @key)
      Application.put_env(:platform, :sign_in_admin_url, nil)
      assert PocketId.delete_user("u1") == {:error, :not_configured}

      assert requests() == []
    end
  end

  # -- secrecy --------------------------------------------------------------

  describe "the key and minted tokens never reach a log or an inspected result" do
    test "every function, on 2xx, 4xx, 5xx and transport error" do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      ok = fn conn, body ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/users"} ->
            json(conn, 200, page([user_json(@static), user_json("u1")], 1, 1))

          {"GET", "/api/users/u1/webauthn-credentials"} ->
            json(conn, 200, [])

          {"GET", "/api/users/u1"} ->
            json(conn, 200, user_json("u1"))

          {"POST", "/api/users/u1/one-time-access-token"} ->
            json(conn, 201, %{"token" => @token})

          {"POST", "/api/users"} ->
            json(conn, 201, user_json("u1", %{"username" => body["username"]}))

          {"PUT", "/api/users/u1"} ->
            json(conn, 200, Map.merge(user_json("u1"), body))

          {"DELETE", "/api/users/u1"} ->
            Plug.Conn.send_resp(conn, 204, "")
        end
      end

      # Error bodies echo the key and the token, so a client that logged or
      # returned a body would be caught here.
      leaky = %{"error" => "nope", "echo" => @key, "token" => @token}

      responders = %{
        ok: ok,
        client_error: fn conn, _ -> json(conn, 401, leaky) end,
        server_error: fn conn, _ -> json(conn, 500, leaky) end,
        transport: fn conn, _ -> Req.Test.transport_error(conn, :closed) end
      }

      calls = [
        fn -> PocketId.list_users() end,
        fn -> PocketId.find_by_email("u1@example.test") end,
        fn -> PocketId.create_user(%{email: "u1@example.test", name: "U One"}) end,
        fn -> PocketId.passkey_count("u1") end,
        fn -> PocketId.one_time_token("u1") end,
        fn -> PocketId.set_disabled("u1", true) end,
        fn -> PocketId.delete_user("u1") end,
        fn -> PocketId.get_user("u1") end
      ]

      {results, log} =
        with_log([level: :debug], fn ->
          for {kind, responder} <- responders, call <- calls do
            stub(responder)
            {kind, call.()}
          end
        end)

      # Positive control: the client's own request line IS captured, so an
      # empty log cannot pass this test.
      assert log =~ "pocket_id.request method=GET path=/api/users status=200"

      assert log =~
               "pocket_id.request method=POST path=/api/users/u1/one-time-access-token status=201"

      assert log =~ "status=transport_error reason=closed"

      refute log =~ @key
      refute log =~ @token

      # The success run really did mint the token, so its absence from the
      # inspected result is the redaction working, not a missing value.
      assert {:ok, %Token{value: @token}} = Keyword.get_values(results, :ok) |> Enum.at(4)

      for {kind, result} <- results do
        rendered = inspect(result)
        refute rendered =~ @key, "#{kind} result inspected the key: #{rendered}"
        refute rendered =~ @token, "#{kind} result inspected a token: #{rendered}"
      end

      refute inspect(Config.api_key()) =~ @key
      requests() |> assert_every_request_keyed()
    end
  end
end
