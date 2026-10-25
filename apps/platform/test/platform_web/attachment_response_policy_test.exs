defmodule PlatformWeb.AttachmentResponsePolicyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test, only: [conn: 2]

  alias PlatformWeb.AttachmentResponsePolicy

  describe "disposition/1" do
    for content_type <- [
          "image/png",
          "image/jpeg",
          "Image/PNG; foo=bar",
          "video/mp4",
          "audio/mpeg",
          "application/pdf",
          "application/pdf; x=1"
        ] do
      test "#{inspect(content_type)} is :inline" do
        assert AttachmentResponsePolicy.disposition(unquote(content_type)) == :inline
      end
    end

    for content_type <- [
          "image/svg+xml",
          "IMAGE/SVG+XML",
          "image/svg+xml; charset=utf-8",
          "text/html",
          "TEXT/HTML; charset=utf-8",
          "text/plain",
          "application/xhtml+xml",
          "application/octet-stream",
          nil
        ] do
      test "#{inspect(content_type)} is :attachment" do
        assert AttachmentResponsePolicy.disposition(unquote(content_type)) == :attachment
      end
    end
  end

  describe "put_sandbox_csp/2" do
    defp base_conn, do: conn(:get, "/")

    test "sets bare sandbox when no CSP exists" do
      conn = AttachmentResponsePolicy.put_sandbox_csp(base_conn())
      assert get_resp_header(conn, "content-security-policy") == ["sandbox;"]
    end

    test "appends to an existing CSP, keeping its directives" do
      conn =
        base_conn()
        |> put_resp_header("content-security-policy", "base-uri 'self'; frame-ancestors 'self';")
        |> AttachmentResponsePolicy.put_sandbox_csp()

      assert get_resp_header(conn, "content-security-policy") == [
               "base-uri 'self'; frame-ancestors 'self'; sandbox;"
             ]
    end

    test "applied twice yields exactly one sandbox directive" do
      conn =
        base_conn()
        |> AttachmentResponsePolicy.put_sandbox_csp()
        |> AttachmentResponsePolicy.put_sandbox_csp()

      [csp] = get_resp_header(conn, "content-security-policy")
      assert length(Regex.scan(~r/sandbox/, csp)) == 1
    end

    test "leaves an existing sandbox directive unchanged" do
      conn =
        base_conn()
        |> put_resp_header(
          "content-security-policy",
          "default-src 'self'; sandbox allow-scripts;"
        )
        |> AttachmentResponsePolicy.put_sandbox_csp()

      assert get_resp_header(conn, "content-security-policy") == [
               "default-src 'self'; sandbox allow-scripts;"
             ]
    end

    test "appends a custom directive" do
      conn =
        base_conn()
        |> put_resp_header("content-security-policy", "frame-ancestors 'self';")
        |> AttachmentResponsePolicy.put_sandbox_csp("sandbox allow-scripts; default-src 'none'")

      assert get_resp_header(conn, "content-security-policy") == [
               "frame-ancestors 'self'; sandbox allow-scripts; default-src 'none'"
             ]
    end
  end
end
