defmodule Platform.GameStream.NativeAPITest do
  use Platform.DataCase, async: false
  alias Platform.GameStream.NativeAPI
  import Plug.Test
  import Plug.Conn

  test "extension admission and publisher endpoints inherit no browser/session authority" do
    previous = Application.fetch_env(:game_stream, :enabled)
    Application.put_env(:game_stream, :enabled, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:game_stream, :enabled, value)
        :error -> Application.delete_env(:game_stream, :enabled)
      end
    end)

    for path <- ["/admit/not-a-uuid", "/builds/not-a-uuid"] do
      c =
        conn(:post, path, %{"token" => "secret"})
        |> assign(:current_user, %{id: "pretend-user"})
        |> NativeAPI.call([])

      assert c.status == 401
      assert c.resp_body == ~s({"error":"unauthorized"})
      refute c.resp_body =~ "secret"
    end

    c =
      conn(:post, "/admit/019d1357-cb08-7023-b165-fd19e9462316?token=secret", %{})
      |> NativeAPI.call([])

    assert c.status == 401

    assert Platform.GameStream.Extension.routes() == [
             %{prefix: "play", plug: NativeAPI, opts: []}
           ]
  end
  test "browser handoff requires a real session and CSRF token" do
    previous = Application.get_env(:game_stream, :enabled)
    Application.put_env(:game_stream, :enabled, true)
    on_exit(fn -> Application.put_env(:game_stream, :enabled, previous) end)
    user = Platform.PrototypeFixtures.user!()

    unauthenticated = conn(:get, "/browser/csrf") |> NativeAPI.call([])
    assert unauthenticated.status == 401

    csrf_conn = conn(:get, "/browser/csrf") |> init_test_session(current_user_id: user.id) |> NativeAPI.call([])
    assert csrf_conn.status == 200
    assert get_resp_header(csrf_conn, "cache-control") == ["no-store"]
    csrf = Jason.decode!(csrf_conn.resp_body)["csrf_token"]
    session = %{"current_user_id" => user.id, "_csrf_token" => get_session(csrf_conn, "_csrf_token")}

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn(:post, "/browser/sessions/not-a-uuid/join", %{}) |> init_test_session(session) |> NativeAPI.call([])
    end

    accepted = conn(:post, "/browser/sessions/not-a-uuid/join", %{}) |> init_test_session(session) |> put_req_header("x-csrf-token", csrf) |> NativeAPI.call([])
    assert accepted.status == 403
    assert accepted.resp_body == ~s({"error":"unauthorized"})
  end

end
