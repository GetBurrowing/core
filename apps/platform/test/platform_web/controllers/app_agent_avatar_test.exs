defmodule PlatformWeb.AppAgentAvatarTest do
  @moduledoc """
  Tests for `GET /api/app/agents/:id/avatar` (task `01a12773` stage 1): the
  bearer-gated twin of `/agents/:id/avatar` that the native app's push
  notification code fetches the sender's picture from.

  ## Coverage matrix

    * 200 with the stored bytes, the content type from
      `AvatarStorage.content_type_for_key/1` and `nosniff`, on a valid bearer.
    * 200 for `Accept: */*`, `image/png`, `image/*` and `image/avif`. The
      browser route's `:accepts ["html", "json"]` 406s the image-only ones,
      so the app pipeline has no `:accepts` plug.
    * 401 with no Authorization header, a revoked bearer, an unknown bearer,
      and a session cookie with no bearer.
    * 404 for an agent with no avatar, and (not 500) for a non-UUID id.
  """

  use PlatformWeb.ConnCase, async: false

  import Platform.ExternalUserFixtures

  alias Platform.Agents.Agent
  alias Platform.Agents.AvatarStorage
  alias Platform.Mobile
  alias Platform.Repo

  setup %{conn: conn} do
    prev = Application.get_env(:platform, :chat_attachments_root)
    scratch = Platform.TestTemp.mkdir!("app_agent_avatar_test")
    Application.put_env(:platform, :chat_attachments_root, scratch)

    on_exit(fn ->
      if prev do
        Application.put_env(:platform, :chat_attachments_root, prev)
      else
        Application.delete_env(:platform, :chat_attachments_root)
      end

      File.rm_rf!(scratch)
    end)

    user = create_user!()
    %{token: token, session: session} = app_session!(user)
    %{conn: conn, user: user, token: token, session: session}
  end

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp png_bytes do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )
  end

  defp pkce do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp app_session!(user) do
    {verifier, challenge} = pkce()
    {:ok, code} = Mobile.issue_exchange_code(user, challenge)
    {:ok, result} = Mobile.exchange_code(code, verifier, %{app_install_id: "install-1"})
    result
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp insert_agent do
    uniq = System.unique_integer([:positive])

    %Agent{}
    |> Agent.changeset(%{
      slug: "app-avatar-agent-#{uniq}",
      name: "App Avatar Agent",
      status: "active",
      workspace_id: Ecto.UUID.generate()
    })
    |> Repo.insert!()
  end

  defp insert_agent_with_avatar(opts \\ []) do
    agent = insert_agent()

    {:ok, result} =
      AvatarStorage.put({:binary, png_bytes()}, agent.id,
        filename: Keyword.get(opts, :filename, "face.png"),
        content_type: Keyword.get(opts, :content_type, "image/png")
      )

    agent =
      agent
      |> Agent.changeset(%{
        avatar_storage_key: result.storage_key,
        avatar_url: "/agents/#{agent.id}/avatar"
      })
      |> Repo.update!()

    {agent, result.storage_key}
  end

  defp path(agent_id), do: "/api/app/agents/#{agent_id}/avatar"

  # ── Tests ──────────────────────────────────────────────────────────────

  describe "valid bearer" do
    test "serves the stored bytes with the key's content type and nosniff", %{
      conn: conn,
      token: token
    } do
      {agent, key} = insert_agent_with_avatar(content_type: "image/webp", filename: "face")

      conn = conn |> bearer(token) |> get(path(agent.id))

      assert conn.status == 200
      assert conn.resp_body == png_bytes()
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      expected_type = AvatarStorage.content_type_for_key(key)
      assert expected_type == "image/webp"
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ expected_type
    end

    test "an image Accept header is not refused", %{conn: conn, token: token} do
      {agent, _key} = insert_agent_with_avatar()

      # `image/png` and `image/*` alone are what `:accepts ["html", "json"]`
      # 406s (measured: Phoenix.NotAcceptableError on `image/png`), which is
      # why the `:app_avatar` pipeline carries no `:accepts` plug.
      for accept <- ["*/*", "image/png", "image/*", "image/avif"] do
        resp =
          conn
          |> recycle()
          |> bearer(token)
          |> put_req_header("accept", accept)
          |> get(path(agent.id))

        assert resp.status == 200, "Accept: #{accept} -> #{resp.status}"
        assert resp.resp_body == png_bytes()
      end
    end

    test "404 for an agent that has no avatar", %{conn: conn, token: token} do
      agent = insert_agent()

      conn = conn |> bearer(token) |> get(path(agent.id))

      assert conn.status == 404
    end

    test "404, not 500, for a non-UUID id", %{conn: conn, token: token} do
      conn = conn |> bearer(token) |> get(path("not-a-uuid"))

      assert conn.status == 404
    end
  end

  # Both Burrow apps drop an avatar body over 256 KB and draw the letter
  # disc (`MAX_BYTES` in AvatarFetcher.kt, `maxBytes` in AvatarFetcher.swift).
  @app_cap 256 * 1024

  # Independent noise per band, so the PNG cannot compress: a 1024 x 1024
  # RGB noise PNG is several MB, like the 0.7-1.4 MB avatars stored in prod.
  defp large_image_bytes(suffix) do
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

  defp insert_agent_with_bytes(bytes, filename, content_type) do
    agent = insert_agent()

    {:ok, result} =
      AvatarStorage.put({:binary, bytes}, agent.id,
        filename: filename,
        content_type: content_type
      )

    agent
    |> Agent.changeset(%{
      avatar_storage_key: result.storage_key,
      avatar_url: "/agents/#{agent.id}/avatar"
    })
    |> Repo.update!()

    {agent, result.storage_key}
  end

  @png_magic <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>

  describe "a large avatar" do
    test "a 1024 px PNG over 256 KB comes back under 256 KB as a 192 px PNG", %{
      conn: conn,
      token: token
    } do
      original = large_image_bytes(".png")
      assert byte_size(original) > @app_cap, "precondition: the fixture must exceed the app cap"
      {agent, _key} = insert_agent_with_bytes(original, "big.png", "image/png")

      conn = conn |> bearer(token) |> get(path(agent.id))

      assert conn.status == 200

      assert byte_size(conn.resp_body) < @app_cap,
             "served #{byte_size(conn.resp_body)} bytes; the apps drop anything over #{@app_cap}"

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "image/png"
      assert <<@png_magic, _::binary>> = conn.resp_body
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      {:ok, image} = Vix.Vips.Image.new_from_buffer(conn.resp_body)
      assert {Vix.Vips.Image.width(image), Vix.Vips.Image.height(image)} == {192, 192}
    end

    test "a large JPEG is served as PNG with a PNG content type", %{conn: conn, token: token} do
      original = large_image_bytes(".jpg[Q=100]")
      assert byte_size(original) > @app_cap, "precondition: the fixture must exceed the app cap"
      {agent, key} = insert_agent_with_bytes(original, "big.jpg", "image/jpeg")
      assert AvatarStorage.content_type_for_key(key) == "image/jpeg"

      conn = conn |> bearer(token) |> get(path(agent.id))

      assert conn.status == 200
      assert byte_size(conn.resp_body) < @app_cap
      # The type describes the bytes served, not the stored original.
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "image/png"
      assert <<@png_magic, _::binary>> = conn.resp_body
    end

    test "the thumbnail is cached beside the original and reused", %{conn: conn, token: token} do
      {agent, key} = insert_agent_with_bytes(large_image_bytes(".png"), "big.png", "image/png")
      thumb_path = Platform.Chat.AttachmentStorage.path_for(AvatarStorage.thumbnail_key(key))
      refute File.exists?(thumb_path)

      first = conn |> bearer(token) |> get(path(agent.id))
      assert File.read!(thumb_path) == first.resp_body

      # Replace the cached file: a second request must serve it, not regenerate.
      File.write!(thumb_path, png_bytes())
      second = conn |> recycle() |> bearer(token) |> get(path(agent.id))
      assert second.resp_body == png_bytes()
    end

    test "deleting the avatar deletes its thumbnail", %{conn: conn, token: token} do
      {agent, key} = insert_agent_with_bytes(large_image_bytes(".png"), "big.png", "image/png")
      thumb_path = Platform.Chat.AttachmentStorage.path_for(AvatarStorage.thumbnail_key(key))

      conn |> bearer(token) |> get(path(agent.id))
      assert File.exists?(thumb_path)

      :ok = AvatarStorage.delete(key)

      refute File.exists?(thumb_path)
      refute File.exists?(Platform.Chat.AttachmentStorage.path_for(key))
    end

    test "an unreadable large original is served as-is, as before thumbnails", %{
      conn: conn,
      token: token
    } do
      garbage = :crypto.strong_rand_bytes(300 * 1024)
      {agent, _key} = insert_agent_with_bytes(garbage, "broken.png", "image/png")

      conn = conn |> bearer(token) |> get(path(agent.id))

      assert conn.status == 200
      assert conn.resp_body == garbage
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "image/png"
    end

    test "the browser route still serves the original", %{conn: conn, user: user} do
      original = large_image_bytes(".png")
      {agent, _key} = insert_agent_with_bytes(original, "big.png", "image/png")

      conn =
        conn
        |> init_test_session(current_user_id: user.id)
        |> get("/agents/#{agent.id}/avatar")

      assert conn.status == 200
      assert conn.resp_body == original
    end
  end

  describe "refused" do
    test "401 with no Authorization header", %{conn: conn} do
      {agent, _key} = insert_agent_with_avatar()

      conn = get(conn, path(agent.id))

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "401 with a revoked bearer", %{conn: conn, token: token, session: session} do
      {agent, _key} = insert_agent_with_avatar()
      {:ok, _} = Mobile.revoke_session(session)

      conn = conn |> bearer(token) |> get(path(agent.id))

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "401 with an unknown bearer", %{conn: conn} do
      {agent, _key} = insert_agent_with_avatar()
      unknown = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

      conn = conn |> bearer(unknown) |> get(path(agent.id))

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "401 for a session cookie with no bearer", %{conn: conn, user: user} do
      # The browser route accepts this exact session; the app route must not.
      {agent, _key} = insert_agent_with_avatar()
      session_conn = init_test_session(conn, current_user_id: user.id)

      assert session_conn |> get("/agents/#{agent.id}/avatar") |> Map.fetch!(:status) == 200

      conn = conn |> init_test_session(current_user_id: user.id) |> get(path(agent.id))

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end
  end
end
