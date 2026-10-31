defmodule PlatformWeb.InstallRequestControllerTest do
  @moduledoc """
  Task 01a18f0c stage 2: `POST /api/install-requests`, the getburrow.ing
  Pages Function's intake. Bearer-authenticated (404 while no token is
  configured, 401 for a missing or wrong one), it hands the request to
  `Platform.Installs.request/1` and never logs a field value.
  """
  # async: false: swaps `config :platform, Platform.Installs` and raises the
  # global Logger level.
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Platform.InstallsFixtures, only: [put_installs_env: 1]

  alias Platform.Installs.Install
  alias Platform.Repo

  @path "/api/install-requests"
  @token "intake-test-token-not-a-real-secret"

  @body %{
    "name" => "Pat Baker",
    "email" => "pat@acme-intake.test",
    "business" => "Acme Bakery",
    "note" => "two locations"
  }

  setup do
    put_installs_env(intake_token: @token)
    :ok
  end

  defp post_request(body, auth \\ "Bearer " <> @token) do
    conn = build_conn() |> put_req_header("content-type", "application/json")
    conn = if auth, do: put_req_header(conn, "authorization", auth), else: conn
    post(conn, @path, Jason.encode!(body))
  end

  defp count, do: Repo.aggregate(from(i in Install), :count)

  test "the route resolves on the bare app host and on a prefixed host, unfenced" do
    for host <- ["example.com", "chat.example.com", "burrow.kobo-ai.com"] do
      info = Phoenix.Router.route_info(PlatformWeb.Router, "POST", @path, host)

      assert %{plug: PlatformWeb.InstallRequestController, plug_opts: :create} = info
      assert info.pipe_through == [:install_intake]
    end
  end

  test "a missing token is 401 and writes nothing" do
    conn = post_request(@body, nil)
    assert conn.status == 401
    assert conn.resp_body == "{}"
    assert count() == 0
  end

  test "a wrong token is 401 and writes nothing" do
    assert post_request(@body, "Bearer wrong-token").status == 401
    assert post_request(@body, @token).status == 401
    assert post_request(@body, "Bearer ").status == 401
    assert count() == 0
  end

  test "with no token configured the route is a 404, whatever is presented" do
    put_installs_env(intake_token: nil)
    assert post_request(@body).status == 404
    assert post_request(@body, "Bearer ").status == 404
    assert count() == 0
  end

  test "the right token creates one requested row; the same email again is a duplicate" do
    conn = post_request(@body)
    assert json_response(conn, 200) == %{"outcome" => "created"}

    assert [%Install{status: "requested", owner_email: "pat@acme-intake.test"}] =
             Repo.all(Install)

    conn = post_request(Map.put(@body, "email", " PAT@acme-intake.test "))
    assert json_response(conn, 200) == %{"outcome" => "duplicate"}
    assert count() == 1
  end

  test "a filled honeypot is ignored and writes nothing" do
    conn = post_request(Map.put(@body, "website", "http://spam.example"))
    assert json_response(conn, 200) == %{"outcome" => "ignored"}
    assert count() == 0
  end

  test "a bad email is a 422 naming the field" do
    conn = post_request(Map.put(@body, "email", "not-an-email"))
    assert json_response(conn, 422) == %{"outcome" => "invalid", "field" => "email"}

    conn = post_request(Map.put(@body, "email", 42))
    assert json_response(conn, 422) == %{"outcome" => "invalid", "field" => "email"}
    assert count() == 0
  end

  test "neither the email, the name nor the note reaches the log" do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    n = System.unique_integer([:positive])
    body = %{@body | "email" => "private-#{n}@acme-intake.test", "name" => "Name #{n}"}
    body = Map.put(body, "note", "secret note #{n}")

    log =
      capture_log([level: :debug], fn ->
        assert json_response(post_request(body), 200) == %{"outcome" => "created"}
      end)

    assert log =~ "[install_requests] outcome=created"
    refute log =~ body["email"]
    refute log =~ body["name"]
    refute log =~ body["note"]
    refute log =~ @token
  end
end
