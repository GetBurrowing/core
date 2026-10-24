defmodule PlatformWeb.ChatLive.LargeUploadHooksTest do
  @moduledoc """
  Task 01a120be: web chat's large-file path. Files over the inline cap are
  staged with the server, reserved on Send through
  `Platform.Chat.reserve_space_upload/3`, and handed to the browser, which
  draws the pending card into the timeline itself (so it survives a socket
  reconnect). The limit and its label are the server's.

  Size strings are computed through `UploadLimits.format_bytes/1`, never
  written out, so these tests follow the one shared decimal rule.
  """
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Attachment
  alias Platform.Chat.AttachmentStorage.Root
  alias Platform.Chat.UploadLimits
  alias Platform.Repo

  setup %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "platform-large-upload-live-#{Ecto.UUID.generate()}")
    Root.put_override(root)

    prev = Application.fetch_env(:platform, :chat_max_upload_bytes)

    on_exit(fn ->
      File.rm_rf(root)

      case prev do
        {:ok, v} -> Application.put_env(:platform, :chat_max_upload_bytes, v)
        :error -> Application.delete_env(:platform, :chat_max_upload_bytes)
      end
    end)

    # A limit distinguishable from any client constant (e2e case 2).
    Application.put_env(:platform, :chat_max_upload_bytes, 1_000_000_000)

    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "large-upload-#{n}@example.com",
        name: "Large Upload User",
        oidc_sub: "oidc-large-upload-#{n}"
      })

    {:ok, view, _html} =
      live(init_test_session(conn, current_user_id: user.id), ~p"/chat/general")

    %{view: view, user: user, space: Chat.get_space_by_slug("general")}
  end

  defp text(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
  end

  defp stage(view, ref, name, size, type \\ "video/quicktime") do
    render_hook(view, "large_upload_stage", %{
      "ref" => ref,
      "name" => name,
      "size" => size,
      "type" => type
    })
  end

  defp uploads_in(payload), do: payload[:uploads] || payload["uploads"]

  test "a staged file over the limit is refused with the server's label in the tray",
       %{view: view} do
    html = stage(view, "r1", "quarterly-raw.mov", 1_153_433_600)
    flat = text(html)

    assert flat =~ "quarterly-raw.mov is 1.2 GB. This Burrow install accepts files up to 1 GB."
    assert html =~ ~s(data-too-large="true")
    # Error hue on the icon only; the words are base-content.
    assert html =~ ~r/hero-exclamation-circle[^"]*text-error/
  end

  test "large_upload_start over the limit replies with the server label and reserves nothing",
       %{view: view, space: space} do
    render_hook(view, "large_upload_start", %{
      "filename" => "huge.mov",
      "content_type" => "video/quicktime",
      "byte_size" => 1_000_000_001
    })

    assert_reply(view, %{
      ok: false,
      error: "file_too_large",
      max_upload_bytes: 1_000_000_000,
      max_upload_label: "1 GB"
    })

    assert Repo.aggregate(from(a in Attachment, where: a.space_id == ^space.id), :count) == 0
  end

  test "large_upload_start under the limit returns a reservation the browser can draw a card from",
       %{view: view, user: user, space: space} do
    html =
      render_hook(view, "large_upload_start", %{
        "ref" => "r2",
        "filename" => "launch-walkthrough.mov",
        "content_type" => "video/quicktime",
        "byte_size" => 900_000_000
      })

    assert_reply(view, %{
      ok: true,
      id: id,
      upload_url: "/chat/attachments/upload/" <> _,
      offset: 0,
      filename: "launch-walkthrough.mov",
      content_type: "video/quicktime",
      byte_size: 900_000_000,
      space_id: space_id,
      participant_id: participant_id
    })

    assert space_id == space.id
    assert %{participant_id: user_id} = Chat.get_space_participant(space.id, participant_id)
    assert user_id == user.id

    row = Repo.get!(Attachment, id)
    assert row.state == "pending"
    assert row.uploaded_by_user_id == user.id

    # The card is the browser's, not a server render: nothing about it is in
    # the LiveView's HTML, so a reconnect (fresh assigns) cannot drop it.
    refute html =~ "launch-walkthrough.mov"
  end

  test "the timeline carries the ignore container and the own-row template, after #message-list",
       %{view: view, space: space} do
    html = render(view)
    doc = LazyHTML.from_document(html)

    [container] = doc |> LazyHTML.query("[data-role=large-upload-timeline]") |> Enum.to_list()
    assert LazyHTML.attribute(container, "phx-update") == ["ignore"]
    assert LazyHTML.attribute(container, "phx-hook") == ["LargeUploadTimeline"]
    assert LazyHTML.attribute(container, "data-space-id") == [space.id]

    # Directly after the message list, inside the scroller: the end of the
    # timeline, not the composer tray.
    assert html =~ ~r/id="message-list".*id="large-upload-timeline-#{space.id}"/s

    assert doc
           |> LazyHTML.query("#chat-message-scroller [data-role=large-upload-timeline]")
           |> Enum.count() == 1

    assert doc |> LazyHTML.query("template#large-upload-row-template") |> Enum.count() == 1
    assert html =~ ~s(data-slot="body")

    # The composer keeps only the hook element.
    [root] = doc |> LazyHTML.query("#large-upload-root") |> Enum.to_list()
    assert LazyHTML.attribute(root, "phx-hook") == ["LargeUpload"]
    assert LazyHTML.text(root) |> String.trim() == ""
  end

  test "Send with only large files reserves them, carries the caption, and posts nothing inline",
       %{view: view, space: space} do
    stage(view, "r3", "a.mov", 20_000_000)
    stage(view, "r4", "b.mov", 1_153_433_600)

    # A too-large file staged blocks the send outright (rung 11): nothing is
    # reserved and nothing posts until it is removed.
    render_submit(view, "send_message", %{"compose" => %{"text" => "the walkthrough"}})
    assert Repo.all(from(a in Attachment, where: a.space_id == ^space.id)) == []

    render_click(view, "large_upload_unstage", %{"ref" => "r4"})
    html = render_submit(view, "send_message", %{"compose" => %{"text" => "the walkthrough"}})

    assert_push_event(view, "large_upload:begin", payload)

    assert [
             %{
               ref: "r3",
               offset: 0,
               upload_url: "/chat/attachments/upload/" <> _,
               filename: "a.mov",
               content: "the walkthrough",
               space_id: space_id
             }
           ] = uploads_in(payload)

    assert space_id == space.id

    # The removed too-large file was never reserved.
    [row] = Repo.all(from(a in Attachment, where: a.space_id == ^space.id))
    assert row.filename == "a.mov"
    assert row.metadata["pending_message"]["content"] == "the walkthrough"
    assert Chat.list_messages(space.id) == []
    refute html =~ "No files selected"
  end

  test "an expired reservation is reserved again through the same path, from 0, with the caption",
       %{view: view, space: space} do
    render_hook(view, "large_upload_start", %{
      "ref" => "r5",
      "filename" => "clip.mov",
      "content_type" => "video/quicktime",
      "byte_size" => 900_000_000
    })

    assert_reply(view, %{ok: true, id: first_id, participant_id: participant_id})

    render_hook(view, "large_upload_rereserve", %{
      "ref" => "r5",
      "expired_id" => first_id,
      "space_id" => space.id,
      "participant_id" => participant_id,
      "filename" => "clip.mov",
      "content_type" => "video/quicktime",
      "byte_size" => 900_000_000,
      "content" => "take two"
    })

    assert_reply(view, %{
      ok: true,
      id: second_id,
      offset: 0,
      upload_url: "/chat/attachments/upload/" <> _,
      content: "take two"
    })

    assert second_id != first_id
    row = Repo.get!(Attachment, second_id)
    assert row.state == "pending"
    assert row.metadata["pending_message"]["content"] == "take two"
    assert row.metadata["pending_message"]["participant_id"] == participant_id
  end

  test "re-reserving refuses a participant that is not this user's in that space",
       %{view: view, space: space} do
    render_hook(view, "large_upload_start", %{
      "ref" => "r7",
      "filename" => "clip.mov",
      "content_type" => "video/quicktime",
      "byte_size" => 900_000_000
    })

    assert_reply(view, %{ok: true, participant_id: participant_id})
    before = Repo.aggregate(from(a in Attachment, where: a.space_id == ^space.id), :count)

    for {space_id, pid} <- [
          {Ecto.UUID.generate(), participant_id},
          {space.id, Ecto.UUID.generate()},
          {space.id, "not-a-uuid"}
        ] do
      render_hook(view, "large_upload_rereserve", %{
        "space_id" => space_id,
        "participant_id" => pid,
        "filename" => "clip.mov",
        "content_type" => "video/quicktime",
        "byte_size" => 900_000_000
      })

      assert_reply(view, %{ok: false, error: "not_a_participant"})
    end

    assert Repo.aggregate(from(a in Attachment, where: a.space_id == ^space.id), :count) ==
             before
  end

  test "re-reserving into a real space this user is not a member of is refused and writes nothing",
       %{view: view} do
    render_hook(view, "large_upload_start", %{
      "ref" => "r8",
      "filename" => "clip.mov",
      "content_type" => "video/quicktime",
      "byte_size" => 900_000_000
    })

    assert_reply(view, %{ok: true, participant_id: participant_id})

    {:ok, other} =
      Chat.create_space(%{
        name: "Elsewhere",
        slug: "elsewhere-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    render_hook(view, "large_upload_rereserve", %{
      "space_id" => other.id,
      "participant_id" => participant_id,
      "filename" => "clip.mov",
      "content_type" => "video/quicktime",
      "byte_size" => 900_000_000
    })

    assert_reply(view, %{ok: false, error: "not_a_participant"})
    assert Repo.aggregate(from(a in Attachment, where: a.space_id == ^other.id), :count) == 0
  end

  test "cancel deletes the pending row", %{view: view} do
    render_hook(view, "large_upload_start", %{
      "ref" => "r6",
      "filename" => "gone.mov",
      "content_type" => "video/quicktime",
      "byte_size" => 50_000_000
    })

    assert_reply(view, %{ok: true, id: id})
    assert Repo.get(Attachment, id)

    render_hook(view, "large_upload_cancel", %{"id" => id})
    assert_reply(view, %{ok: true})

    assert Repo.get(Attachment, id) == nil
  end

  test "the posted attachment chip reads its size by the same rule as the pending card" do
    for n <- [512, 8_000_000, 33_554_432, 899_109_076, 1_073_741_824] do
      assert PlatformWeb.Components.ChatHelpers.format_bytes(n) == UploadLimits.format_bytes(n)
    end
  end
end
