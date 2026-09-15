defmodule Platform.Files.Extractor.AudioTest do
  use ExUnit.Case, async: false

  alias Platform.Files.Extractor.Audio

  setup do
    {:ok, _} = Application.ensure_all_started(:req)

    previous = Application.get_env(:platform, :files_service)

    Application.put_env(:platform, :files_service,
      base_url: "http://files-service:8200",
      token: "devtoken",
      timeout: 1_000
    )

    on_exit(fn ->
      Application.delete_env(:platform, :files_service_req_client)

      if previous,
        do: Application.put_env(:platform, :files_service, previous),
        else: Application.delete_env(:platform, :files_service)
    end)

    :ok
  end

  defp install_stub(fun) do
    Req.Test.stub(:audio_extractor_test, fun)

    Application.put_env(
      :platform,
      :files_service_req_client,
      Req.new(plug: {Req.Test, :audio_extractor_test})
    )
  end

  test "delegates to ServiceClient with the given audio content type" do
    test_pid = self()

    install_stub(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req, conn, body})
      Req.Test.json(conn, %{"text" => "hello there", "pages" => nil})
    end)

    assert {:ok, %{text: "hello there", pages: nil}} =
             Audio.extract("id3 mpeg bytes", "audio/mpeg")

    assert_receive {:req, conn, body}
    assert conn.request_path == "/extract"
    assert body =~ "id3 mpeg bytes"
    assert body =~ "audio/mpeg"
  end

  test "forwards the exact content type it was called with, not a hardcoded default" do
    test_pid = self()

    install_stub(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req, conn, body})
      Req.Test.json(conn, %{"text" => "transcript", "pages" => nil})
    end)

    assert {:ok, %{text: "transcript", pages: nil}} =
             Audio.extract("ogg bytes", "audio/ogg")

    assert_receive {:req, _conn, body}
    assert body =~ "audio/ogg"
  end

  test "returns :service_disabled when no files_service config" do
    Application.delete_env(:platform, :files_service)
    assert {:error, :service_disabled} = Audio.extract("anything", "audio/wav")
  end

  test "propagates :tool_unavailable from the service" do
    install_stub(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "tool_unavailable"}))
    end)

    assert {:error, :tool_unavailable} = Audio.extract("bytes", "audio/m4a")
  end
end
