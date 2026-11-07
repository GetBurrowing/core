defmodule Platform.GameStream.NativeAPITest do
  use ExUnit.Case, async: false
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
end
