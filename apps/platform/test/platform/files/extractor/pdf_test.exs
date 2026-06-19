defmodule Platform.Files.Extractor.PDFTest do
  use ExUnit.Case, async: false

  alias Platform.Files.Extractor.PDF

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
    Req.Test.stub(:pdf_extractor_test, fun)

    Application.put_env(
      :platform,
      :files_service_req_client,
      Req.new(plug: {Req.Test, :pdf_extractor_test})
    )
  end

  test "delegates to ServiceClient with application/pdf content type" do
    test_pid = self()

    install_stub(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req, conn, body})
      Req.Test.json(conn, %{"text" => "page1\fpage2", "pages" => ["page1", "page2"]})
    end)

    assert {:ok, %{text: "page1\fpage2", pages: ["page1", "page2"]}} =
             PDF.extract("%PDF-1.4 bytes")

    assert_receive {:req, conn, body}
    assert conn.request_path == "/extract"
    assert body =~ "%PDF-1.4 bytes"
    assert body =~ "application/pdf"
  end

  test "returns :service_disabled when no files_service config" do
    Application.delete_env(:platform, :files_service)
    assert {:error, :service_disabled} = PDF.extract("anything")
  end

  test "propagates :tool_unavailable from the service" do
    install_stub(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "tool_unavailable"}))
    end)

    assert {:error, :tool_unavailable} = PDF.extract("bytes")
  end
end
