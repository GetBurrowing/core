defmodule Platform.Files.ServiceClientTest do
  use ExUnit.Case, async: false

  alias Platform.Files.ServiceClient

  @config [
    base_url: "http://files-service:8200",
    token: "devtoken",
    timeout: 1_000
  ]

  setup do
    {:ok, _} = Application.ensure_all_started(:req)

    previous = Application.get_env(:platform, :files_service)
    Application.put_env(:platform, :files_service, @config)

    on_exit(fn ->
      Application.delete_env(:platform, :files_service_req_client)

      if previous,
        do: Application.put_env(:platform, :files_service, previous),
        else: Application.delete_env(:platform, :files_service)
    end)

    :ok
  end

  defp install_stub(fun) do
    Req.Test.stub(:files_service_test, fun)

    Application.put_env(
      :platform,
      :files_service_req_client,
      Req.new(plug: {Req.Test, :files_service_test})
    )
  end

  describe "extract/2" do
    test "POSTs /extract with multipart body and bearer header, returning text + pages" do
      test_pid = self()

      install_stub(fn conn ->
        send(test_pid, {:req, conn})

        Req.Test.json(conn, %{
          "text" => "page one\f\npage two",
          "pages" => ["page one", "page two"],
          "metadata" => %{"extractor" => "pypdf", "duration_ms" => 12}
        })
      end)

      assert {:ok, %{text: text, pages: pages}} =
               ServiceClient.extract("%PDF-1.4 fake", "application/pdf")

      assert text == "page one\f\npage two"
      assert pages == ["page one", "page two"]

      assert_receive {:req, conn}
      assert conn.request_path == "/extract"
      assert conn.method == "POST"

      headers = Map.new(conn.req_headers)
      assert headers["authorization"] == "Bearer devtoken"

      ct = headers["content-type"]
      assert is_binary(ct)
      assert ct =~ "multipart/form-data"
      assert ct =~ "boundary="
    end

    test "multipart body carries the file bytes and the content_type field" do
      install_stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert body =~ "%PDF-1.4 fake-bytes"
        assert body =~ "application/pdf"
        assert body =~ "name=\"content_type\""
        assert body =~ "name=\"file\""

        Req.Test.json(conn, %{"text" => "extracted", "pages" => nil})
      end)

      assert {:ok, %{text: "extracted", pages: nil}} =
               ServiceClient.extract("%PDF-1.4 fake-bytes", "application/pdf")
    end

    test "returns {:error, :unsupported_type} on 415" do
      install_stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(415, Jason.encode!(%{"error" => "unsupported_type"}))
      end)

      assert {:error, :unsupported_type} =
               ServiceClient.extract("bytes", "application/x-weird")
    end

    test "returns {:error, :tool_unavailable} on 500 with error=tool_unavailable" do
      install_stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          500,
          Jason.encode!(%{"error" => "tool_unavailable", "detail" => "pdftotext missing"})
        )
      end)

      assert {:error, :tool_unavailable} =
               ServiceClient.extract("bytes", "application/pdf")
    end

    test "returns {:error, {:http, status, body}} on other non-2xx" do
      install_stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, Jason.encode!(%{"detail" => "service overloaded"}))
      end)

      assert {:error, {:http, 503, %{"detail" => "service overloaded"}}} =
               ServiceClient.extract("bytes", "application/pdf")
    end

    test "returns {:error, reason} on transport error" do
      install_stub(fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               ServiceClient.extract("bytes", "application/pdf")
    end

    test "returns {:error, :service_disabled} when no :files_service config" do
      Application.delete_env(:platform, :files_service)

      assert {:error, :service_disabled} = ServiceClient.extract("bytes", "application/pdf")
    end

    test "returns {:error, :service_disabled} when base_url is nil" do
      Application.put_env(:platform, :files_service, base_url: nil, token: "x")

      assert {:error, :service_disabled} = ServiceClient.extract("bytes", "application/pdf")
    end

    test "returns {:error, :service_disabled} when base_url is empty string" do
      Application.put_env(:platform, :files_service, base_url: "", token: "x")

      assert {:error, :service_disabled} = ServiceClient.extract("bytes", "application/pdf")
    end

    test "omits Authorization header when no token configured" do
      Application.put_env(:platform, :files_service,
        base_url: "http://files-service:8200",
        timeout: 1_000
      )

      test_pid = self()

      install_stub(fn conn ->
        send(test_pid, {:req, conn})
        Req.Test.json(conn, %{"text" => "ok", "pages" => nil})
      end)

      assert {:ok, _} = ServiceClient.extract("bytes", "application/pdf")

      assert_receive {:req, conn}
      headers = Map.new(conn.req_headers)
      refute Map.has_key?(headers, "authorization")
    end
  end

  describe "telemetry" do
    test "emits :extracted on success and :error on failure" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :files, :extracted],
          [:platform, :files, :error]
        ])

      install_stub(fn conn ->
        Req.Test.json(conn, %{"text" => "hello", "pages" => nil})
      end)

      assert {:ok, _} = ServiceClient.extract("bytes", "application/pdf")

      assert_received {[:platform, :files, :extracted], ^ref, measurements, metadata}
      assert is_integer(measurements.duration)
      assert measurements.text_bytes == byte_size("hello")
      assert metadata.content_type == "application/pdf"

      install_stub(fn conn ->
        Plug.Conn.resp(conn, 415, "")
      end)

      assert {:error, :unsupported_type} = ServiceClient.extract("bytes", "image/png")

      assert_received {[:platform, :files, :error], ^ref, _m, error_meta}
      assert error_meta.content_type == "image/png"
      assert error_meta.reason == :unsupported_type
    end
  end
end
