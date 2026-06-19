defmodule Platform.Files.Extractor.ImageTest do
  use ExUnit.Case, async: false

  alias Platform.Files.Extractor.Image

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
    Req.Test.stub(:image_extractor_test, fun)

    Application.put_env(
      :platform,
      :files_service_req_client,
      Req.new(plug: {Req.Test, :image_extractor_test})
    )
  end

  test "extract/1 defaults to image/png" do
    test_pid = self()

    install_stub(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req, body})
      Req.Test.json(conn, %{"text" => "HELLO OCR", "pages" => nil})
    end)

    assert {:ok, %{text: "HELLO OCR", pages: nil}} = Image.extract("\x89PNG\r\n")

    assert_receive {:req, body}
    assert body =~ "image/png"
  end

  test "extract/2 honors the supplied content_type" do
    test_pid = self()

    install_stub(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req, body})
      Req.Test.json(conn, %{"text" => "from jpeg", "pages" => nil})
    end)

    assert {:ok, %{text: "from jpeg", pages: nil}} =
             Image.extract("\xFF\xD8\xFF fake jpeg", "image/jpeg")

    assert_receive {:req, body}
    assert body =~ "image/jpeg"
  end

  test "returns :service_disabled when unconfigured" do
    Application.delete_env(:platform, :files_service)
    assert {:error, :service_disabled} = Image.extract("png bytes")
  end
end
