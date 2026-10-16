defmodule PlatformWeb.ControlCenter.AgentAvatarUploadTest do
  @moduledoc """
  End-to-end coverage for the agent-avatar upload on the Control Center
  config form (task `01a00122` stage 2).

  These drive the real LiveView through `file_input/4` + `render_upload/2`
  and then submit the real form, so they exercise `allow_upload/3`,
  `consume_uploaded_entry/3`, `AvatarStorage.put/3` and
  `Agent.changeset/2` together rather than any of them in isolation.

  ## Two different rejections, and why both are here

  `Phoenix.LiveView.UploadConfig.accepted?/2` short-circuits the moment an
  entry's `client_type` is on the accept list and never looks at the
  filename. So:

    * An HONEST SVG (`type: "image/svg+xml"`) never reaches application
      code — LiveView bounces it at preflight. That test is real coverage
      of the `accept` list, but it is NOT coverage of any check this stage
      wrote, and it stays green if that check is deleted.
    * A DISGUISED SVG (`name: "payload.svg"`, `type: "image/png"`) clears
      both LiveView's accept validation and `AvatarStorage.put/3`, because
      both trust the reported type. It is caught only by
      `AgentAvatarUpload.allowed_entry?/1`.

  The second test is therefore the one that carries the "SVG is rejected
  server-side" claim, and the first test asserts explicitly that the
  disguise DOES get past the accept layer — otherwise the second test
  would be quietly measuring the same thing as the first.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Agents.Agent
  alias Platform.Chat.AttachmentStorage
  alias Platform.Repo
  alias PlatformWeb.ControlCenter.AgentAvatarUpload

  @form "#agent-config-form"

  # Point the attachment store at a per-test scratch dir, isolated from the
  # shared per-run root `test.exs` configures. Global env, hence
  # `async: false`.
  setup do
    prev = Application.get_env(:platform, :chat_attachments_root)

    scratch =
      Platform.TestTemp.mkdir!("agent_avatar_upload_test")

    Application.put_env(:platform, :chat_attachments_root, scratch)

    on_exit(fn ->
      if prev do
        Application.put_env(:platform, :chat_attachments_root, prev)
      else
        Application.delete_env(:platform, :chat_attachments_root)
      end

      File.rm_rf!(scratch)
    end)

    :ok
  end

  defp authenticated_conn(conn) do
    user = Platform.TenancyFixtures.root_admin!()

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_agent(attrs \\ %{}) do
    defaults = %{
      slug: "avatar-agent-#{System.unique_integer([:positive, :monotonic])}",
      name: "Avatar Agent",
      status: "active",
      max_concurrent: 1,
      sandbox_mode: "off",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    }

    %Agent{}
    |> Agent.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  # A real one-pixel PNG, so what gets stored is an image rather than an
  # arbitrary blob that happens to be named `.png`.
  defp png_bytes do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )
  end

  # The payload the allowlist exists to keep out: an SVG carrying script.
  defp svg_bytes do
    ~S|<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>|
  end

  defp upload_avatar(view, entry) do
    upload = file_input(view, @form, AgentAvatarUpload.upload_name(), [entry])
    {upload, render_upload(upload, entry.name)}
  end

  defp submit_config(view) do
    view |> form(@form) |> render_submit()
  end

  defp reload(%Agent{id: id}), do: Repo.get!(Agent, id)

  defp blob_path(%Agent{avatar_storage_key: key}) when is_binary(key),
    do: AttachmentStorage.path_for(key)

  describe "uploading an image" do
    test "a PNG sets both avatar columns, writes the blob and renders the image", %{conn: conn} do
      agent = create_agent()
      conn = authenticated_conn(conn)
      {:ok, view, html} = live(conn, ~p"/control/#{agent.slug}")

      # Empty state: the fallback is showing and there is nothing to remove.
      assert html =~ "Avatar"
      assert html =~ ~s(data-avatar-kind="agent-fallback")
      refute html =~ ~s(phx-click="remove_avatar")

      {_upload, _} =
        upload_avatar(view, %{name: "face.png", content: png_bytes(), type: "image/png"})

      html = submit_config(view)

      saved = reload(agent)

      # Both columns, not just the URL. `avatar_storage_key` is what makes
      # the blob deletable later; a test that only asserted `avatar_url`
      # would pass on an implementation that leaks every blob forever.
      assert is_binary(saved.avatar_storage_key)
      assert String.starts_with?(saved.avatar_storage_key, "agent-avatars/#{agent.id}/")
      assert String.ends_with?(saved.avatar_storage_key, ".png")
      assert is_binary(saved.avatar_url)
      assert saved.avatar_url =~ "/agents/#{agent.id}/avatar"

      # The bytes really landed, and they are the bytes we sent.
      assert File.read!(blob_path(saved)) == png_bytes()

      # And the form now renders the image instead of the initials fallback.
      assert html =~ ~s(data-avatar-kind="agent")
      refute html =~ ~s(data-avatar-kind="agent-fallback")
      assert html =~ "/agents/#{agent.id}/avatar"
      assert html =~ ~s(phx-click="remove_avatar")
    end

    test "the upload does not disturb the rest of the config form", %{conn: conn} do
      agent = create_agent(%{name: "Keepsake", max_concurrent: 3})
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

      {_upload, _} =
        upload_avatar(view, %{name: "face.png", content: png_bytes(), type: "image/png"})

      submit_config(view)

      saved = reload(agent)

      # A positive control for the two rejection tests below: this is what
      # "the save went through" looks like on the non-avatar fields, so a
      # rejection that silently dropped the whole save would be visible.
      assert saved.name == "Keepsake"
      assert saved.max_concurrent == 3
      assert saved.model_config["primary"] == "anthropic/claude-sonnet-4-6"
      assert is_binary(saved.avatar_storage_key)
    end
  end

  describe "SVG rejection" do
    test "an honest SVG is bounced by the accept list and writes no row change", %{conn: conn} do
      agent = create_agent()
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

      {_upload, result} =
        upload_avatar(view, %{name: "payload.svg", content: svg_bytes(), type: "image/svg+xml"})

      # Rejected at preflight — this never reaches `consume/2`.
      assert {:error, [[_ref, :not_accepted]]} = result

      html = submit_config(view)

      saved = reload(agent)
      assert saved.avatar_url == nil
      assert saved.avatar_storage_key == nil

      # The operator is told why, rather than the file vanishing silently.
      assert html =~ "not supported"
    end

    test "an SVG disguised as a PNG clears the accept list and is rejected server-side", %{
      conn: conn
    } do
      agent = create_agent()
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

      {_upload, result} =
        upload_avatar(view, %{name: "payload.svg", content: svg_bytes(), type: "image/png"})

      # The load-bearing half of this test: the disguise DOES get past
      # LiveView's `accept` validation, so whatever rejects it below is
      # application code and not the accept list.
      refute match?({:error, _}, result)

      html = submit_config(view)

      saved = reload(agent)
      assert saved.avatar_url == nil
      assert saved.avatar_storage_key == nil

      assert html =~ "not supported"

      # Nothing was written to storage either — a rejection that stored the
      # bytes and merely skipped the columns would still be a leak.
      assert Path.wildcard(
               Path.join([
                 Application.get_env(:platform, :chat_attachments_root),
                 "agent-avatars",
                 agent.id,
                 "*"
               ])
             ) == []
    end
  end

  describe "replacing an avatar" do
    test "the previous blob is deleted rather than leaked", %{conn: conn} do
      agent = create_agent()
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

      {_upload, _} =
        upload_avatar(view, %{name: "first.png", content: png_bytes(), type: "image/png"})

      submit_config(view)

      first = reload(agent)
      first_path = blob_path(first)
      assert File.exists?(first_path)

      {_upload, _} =
        upload_avatar(view, %{name: "second.png", content: png_bytes(), type: "image/png"})

      submit_config(view)

      second = reload(agent)
      second_path = blob_path(second)

      # A new key, so the serving URL changes with the bytes.
      assert second.avatar_storage_key != first.avatar_storage_key
      assert second.avatar_url != first.avatar_url
      assert File.exists?(second_path)

      # THE assertion for this stage: the superseded blob is gone. Without
      # it every replaced avatar stays in the bucket forever, and nothing
      # else in the system will ever collect it.
      refute File.exists?(first_path)
    end
  end

  describe "removing an avatar" do
    test "clears both columns, deletes the blob and restores the fallback", %{conn: conn} do
      agent = create_agent()
      conn = authenticated_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/control/#{agent.slug}")

      {_upload, _} =
        upload_avatar(view, %{name: "face.png", content: png_bytes(), type: "image/png"})

      submit_config(view)

      uploaded = reload(agent)
      path = blob_path(uploaded)
      assert File.exists?(path)

      html = render_click(view, "remove_avatar", %{})

      cleared = reload(agent)
      assert cleared.avatar_url == nil
      assert cleared.avatar_storage_key == nil
      refute File.exists?(path)

      # Back to the initial state, not to a broken <img>.
      assert html =~ ~s(data-avatar-kind="agent-fallback")
      refute html =~ ~s(data-avatar-kind="agent")
      assert html =~ "Removed the avatar"
    end
  end
end
