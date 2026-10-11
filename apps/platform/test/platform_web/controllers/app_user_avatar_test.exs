defmodule PlatformWeb.AppUserAvatarTest do
  @moduledoc """
  `GET /api/app/users/:id/avatar`: a member's `users.avatar_url`, fetched by
  the install and served at a size both Burrow apps accept (they drop a body
  over 256 KB: `MAX_BYTES` in AvatarFetcher.kt, `maxBytes` in
  AvatarFetcher.swift).

  The remote host is the `Req.Test` stub named `Platform.Accounts.UserAvatarCache`;
  DNS is `:user_avatar_resolver`, stubbed per test to a public address.
  """

  use PlatformWeb.ConnCase, async: false

  import Platform.ExternalUserFixtures

  alias Platform.Accounts.User
  alias Platform.Mobile
  alias Platform.Repo

  @stub Platform.Accounts.UserAvatarCache
  @app_cap 256 * 1024
  @png_magic <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>

  setup %{conn: conn} do
    prev_root = Application.get_env(:platform, :chat_attachments_root)
    prev_resolver = Application.get_env(:platform, :user_avatar_resolver)
    scratch = Platform.TestTemp.mkdir!("app_user_avatar_test")
    Application.put_env(:platform, :chat_attachments_root, scratch)
    # The IdP host resolves to a public address.
    Application.put_env(:platform, :user_avatar_resolver, %{"idp.example" => [{93, 184, 216, 34}]})

    on_exit(fn ->
      if prev_root,
        do: Application.put_env(:platform, :chat_attachments_root, prev_root),
        else: Application.delete_env(:platform, :chat_attachments_root)

      Application.put_env(:platform, :user_avatar_resolver, prev_resolver)
      File.rm_rf!(scratch)
    end)

    viewer = create_user!()
    {verifier, challenge} = pkce()
    {:ok, code} = Mobile.issue_exchange_code(viewer, challenge)
    {:ok, %{token: token}} = Mobile.exchange_code(code, verifier, %{app_install_id: "install-1"})

    %{conn: conn, token: token, viewer: viewer}
  end

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp pkce do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp small_png do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )
  end

  # Independent noise per band, so the image cannot compress.
  defp large_image(suffix) do
    bands =
      for _ <- 1..3 do
        {:ok, noise} = Vix.Vips.Operation.gaussnoise(1024, 1024, mean: 128.0, sigma: 60.0)
        {:ok, u8} = Vix.Vips.Operation.cast(noise, :VIPS_FORMAT_UCHAR)
        u8
      end

    {:ok, rgb} = Vix.Vips.Operation.bandjoin(bands)
    {:ok, bytes} = Vix.Vips.Image.write_to_buffer(rgb, suffix)
    bytes
  end

  defp user_with_avatar!(url) do
    create_user!()
    |> Ecto.Changeset.change(avatar_url: url)
    |> Repo.update!()
  end

  # Serves `body` as `content_type` and counts the requests it answers.
  defp serve(body, content_type, status \\ 200) do
    counter = :counters.new(1, [])

    Req.Test.stub(@stub, fn conn ->
      :counters.add(counter, 1, 1)

      conn
      |> Plug.Conn.put_resp_content_type(content_type, nil)
      |> Plug.Conn.send_resp(status, body)
    end)

    counter
  end

  defp hits(counter), do: :counters.get(counter, 1)

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
  defp path(id), do: "/api/app/users/#{id}/avatar"

  defp get_avatar(conn, token, id), do: conn |> recycle() |> bearer(token) |> get(path(id))

  # ── Sizing ─────────────────────────────────────────────────────────────

  describe "sizing" do
    test "a source over 256 KB comes back under 256 KB as a 192 px PNG", %{
      conn: conn,
      token: token
    } do
      original = large_image(".png")
      assert byte_size(original) > @app_cap, "precondition: fixture must exceed the app cap"
      user = user_with_avatar!("https://idp.example/big.png")
      serve(original, "image/png")

      conn = get_avatar(conn, token, user.id)

      assert conn.status == 200

      assert byte_size(conn.resp_body) < @app_cap,
             "served #{byte_size(conn.resp_body)} bytes; the apps drop anything over #{@app_cap}"

      assert <<@png_magic, _::binary>> = conn.resp_body
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "image/png"
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      {:ok, image} = Vix.Vips.Image.new_from_buffer(conn.resp_body)
      assert {Vix.Vips.Image.width(image), Vix.Vips.Image.height(image)} == {192, 192}
    end

    test "a large JPEG is served as a PNG thumbnail", %{conn: conn, token: token} do
      original = large_image(".jpg[Q=100]")
      assert byte_size(original) > @app_cap
      user = user_with_avatar!("https://idp.example/big.jpg")
      serve(original, "image/jpeg")

      conn = get_avatar(conn, token, user.id)

      assert conn.status == 200
      assert byte_size(conn.resp_body) < @app_cap
      assert <<@png_magic, _::binary>> = conn.resp_body
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "image/png"
    end

    test "a small source passes through unchanged, with its own type", %{conn: conn, token: token} do
      user = user_with_avatar!("https://idp.example/small.png")
      serve(small_png(), "image/png")

      conn = get_avatar(conn, token, user.id)

      assert conn.status == 200
      assert conn.resp_body == small_png()
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "image/png"
    end
  end

  # ── Cache ──────────────────────────────────────────────────────────────

  describe "cache" do
    test "a second request is served from the cache", %{conn: conn, token: token} do
      user = user_with_avatar!("https://idp.example/small.png")
      counter = serve(small_png(), "image/png")

      assert get_avatar(conn, token, user.id).resp_body == small_png()
      assert get_avatar(conn, token, user.id).resp_body == small_png()
      assert hits(counter) == 1
    end

    test "a changed avatar_url is fetched afresh", %{conn: conn, token: token} do
      user = user_with_avatar!("https://idp.example/one.png")
      counter = serve(small_png(), "image/png")
      assert get_avatar(conn, token, user.id).status == 200

      user |> Ecto.Changeset.change(avatar_url: "https://idp.example/two.png") |> Repo.update!()
      large = large_image(".png")
      serve(large, "image/png")

      conn = get_avatar(conn, token, user.id)
      assert conn.status == 200
      assert conn.resp_body != small_png()
      assert <<@png_magic, _::binary>> = conn.resp_body
      assert hits(counter) == 1
    end
  end

  # ── Clean fallbacks: always 404, never 500 ─────────────────────────────

  describe "falls back to the letter (404)" do
    test "a non-image content type", %{conn: conn, token: token} do
      user = user_with_avatar!("https://idp.example/page")
      serve("<html>hi</html>", "text/html")

      assert get_avatar(conn, token, user.id).status == 404
    end

    test "SVG, which can carry script", %{conn: conn, token: token} do
      user = user_with_avatar!("https://idp.example/face.svg")
      serve(~s(<svg xmlns="http://www.w3.org/2000/svg"/>), "image/svg+xml")

      assert get_avatar(conn, token, user.id).status == 404
    end

    test "bytes labelled as an image that are not one", %{conn: conn, token: token} do
      user = user_with_avatar!("https://idp.example/fake.png")
      serve(:crypto.strong_rand_bytes(300 * 1024), "image/png")

      assert get_avatar(conn, token, user.id).status == 404
    end

    test "a source over the 5 MB fetch cap", %{conn: conn, token: token} do
      user = user_with_avatar!("https://idp.example/huge.png")
      serve(:binary.copy(<<0>>, 5 * 1024 * 1024 + 1), "image/png")

      assert get_avatar(conn, token, user.id).status == 404
    end

    test "a redirect, which is never followed", %{conn: conn, token: token} do
      user = user_with_avatar!("https://idp.example/moved.png")

      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest/meta-data")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert get_avatar(conn, token, user.id).status == 404
    end

    test "a host that resolves to a private address is never contacted", %{
      conn: conn,
      token: token
    } do
      for {host, ip} <- [
            {"internal.example", {10, 0, 0, 5}},
            {"metadata.example", {169, 254, 169, 254}},
            {"loop.example", {127, 0, 0, 1}},
            {"v6loop.example", {0, 0, 0, 0, 0, 0, 0, 1}}
          ] do
        Application.put_env(:platform, :user_avatar_resolver, %{host => [ip]})
        user = user_with_avatar!("https://#{host}/face.png")
        counter = serve(small_png(), "image/png")

        assert get_avatar(conn, token, user.id).status == 404, host
        assert hits(counter) == 0, "#{host} was contacted"
      end
    end

    test "an IP-literal avatar url on a private address", %{conn: conn, token: token} do
      user = user_with_avatar!("https://127.0.0.1/face.png")
      counter = serve(small_png(), "image/png")

      assert get_avatar(conn, token, user.id).status == 404
      assert hits(counter) == 0
    end

    test "a non-https avatar_url is never fetched", %{conn: conn, token: token} do
      counter = serve(small_png(), "image/png")

      for url <- ["http://idp.example/face.png", "/uploads/face.png", "", nil] do
        user = user_with_avatar!(url)
        assert get_avatar(conn, token, user.id).status == 404, inspect(url)
      end

      assert hits(counter) == 0
    end

    test "an upstream error status", %{conn: conn, token: token} do
      user = user_with_avatar!("https://idp.example/gone.png")
      serve("nope", "image/png", 500)

      assert get_avatar(conn, token, user.id).status == 404
    end

    test "a failure is remembered: no refetch, and the push omits the avatar", %{
      conn: conn,
      token: token
    } do
      user = user_with_avatar!("https://idp.example/page")
      counter = serve("<html/>", "text/html")

      assert get_avatar(conn, token, user.id).status == 404
      assert get_avatar(conn, token, user.id).status == 404
      assert hits(counter) == 1

      assert Platform.Accounts.UserAvatarCache.push_url(Repo.get!(User, user.id)) == nil
    end

    test "an unknown user, and a non-UUID id", %{conn: conn, token: token} do
      assert get_avatar(conn, token, Ecto.UUID.generate()).status == 404
      assert get_avatar(conn, token, "not-a-uuid").status == 404
    end

    test "a query string never chooses the url", %{conn: conn, token: token} do
      user = user_with_avatar!(nil)
      counter = serve(small_png(), "image/png")

      conn =
        conn
        |> bearer(token)
        |> get(
          path(user.id) <> "?url=https://idp.example/x.png&avatar_url=https://idp.example/x.png"
        )

      assert conn.status == 404
      assert hits(counter) == 0
    end
  end

  describe "authentication (same as the agent app avatar route)" do
    test "401 with no bearer", %{conn: conn} do
      user = user_with_avatar!("https://idp.example/small.png")
      assert json_response(get(conn, path(user.id)), 401) == %{"error" => "unauthorized"}
    end

    test "401 for a session cookie with no bearer", %{conn: conn, viewer: viewer} do
      user = user_with_avatar!("https://idp.example/small.png")

      conn = conn |> init_test_session(current_user_id: viewer.id) |> get(path(user.id))

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end
  end
end
