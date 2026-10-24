defmodule Platform.Chat.AttachmentLinksTest do
  @moduledoc """
  Task 01a1655c stage 3: `/chat/attachments/<uuid>` links in message text
  resolve to the video/image attachments the viewer may read.

  The deny-equality case pins the batch decision to
  `Chat.get_visible_attachment_for_principal/2`, the download route's check,
  on allowed and denied rows for several viewers.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.AttachmentLinks
  alias Platform.Chat.Message
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  defp origin do
    uri = PlatformWeb.Endpoint.struct_url()
    "#{uri.scheme}://#{uri.host}:#{uri.port}"
  end

  defp user! do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{email: "al-#{n}@example.com", name: "U #{n}", oidc_sub: "al-#{n}"})
    |> Repo.insert!()
  end

  defp channel! do
    {:ok, space} =
      Chat.create_space(%{
        name: "Links",
        slug: "links-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp seat!(space, user) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp post!(space, participant, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })

    msg
  end

  defp attachment!(attrs) do
    {:ok, att} =
      Chat.create_attachment(
        Map.merge(
          %{
            filename: "clip.mp4",
            content_type: "video/mp4",
            byte_size: 10,
            storage_key: "k-#{System.unique_integer([:positive])}"
          },
          attrs
        )
      )

    att
  end

  describe "ids_in/1" do
    test "an absolute link whose host and port equal the endpoint's" do
      id = Ecto.UUID.generate()
      assert AttachmentLinks.ids_in("look #{origin()}/chat/attachments/#{id} ok") == [id]
    end

    test "a path-relative link, bare or in markdown" do
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()

      assert AttachmentLinks.ids_in("/chat/attachments/#{a}\n[clip](/chat/attachments/#{b})") ==
               [a, b]
    end

    test "other hosts, other ports and lookalike hosts are ignored" do
      id = Ecto.UUID.generate()
      uri = PlatformWeb.Endpoint.struct_url()

      for url <- [
            "https://evil.example.com/chat/attachments/#{id}",
            "#{uri.scheme}://#{uri.host}:#{uri.port + 1}/chat/attachments/#{id}",
            "#{uri.scheme}://#{uri.host}:#{uri.port}.evil.com/chat/attachments/#{id}",
            "#{uri.scheme}://#{uri.host}:#{uri.port}@evil.com/chat/attachments/#{id}",
            "https://evil.example.com/x/chat/attachments/#{id}"
          ] do
        assert AttachmentLinks.ids_in("see #{url}") == [], url
      end
    end

    test "an invalid uuid is ignored" do
      assert AttachmentLinks.ids_in("/chat/attachments/------------------------------------") ==
               []

      assert AttachmentLinks.ids_in("/chat/attachments/zzzzzzzz-0000-7000-8000-000000000000") ==
               []

      assert AttachmentLinks.ids_in("/chat/attachments/upload/sometoken") == []
    end
  end

  describe "resolve_for_viewer/2" do
    test "keeps video/* and image/* rows, drops other content types" do
      viewer = user!()
      space = channel!()
      p = seat!(space, viewer)

      video = attachment!(%{space_id: space.id})
      image = attachment!(%{space_id: space.id, content_type: "image/png", filename: "a.png"})
      pdf = attachment!(%{space_id: space.id, content_type: "application/pdf", filename: "a.pdf"})

      msg =
        post!(
          space,
          p,
          "/chat/attachments/#{video.id} /chat/attachments/#{pdf.id} /chat/attachments/#{image.id}"
        )

      assert %{} = map = AttachmentLinks.resolve_for_viewer([msg], {:user, viewer.id})
      assert Enum.map(Map.fetch!(map, msg.id), & &1.id) == [video.id, image.id]
    end

    test "batch decision equals get_visible_attachment_for_principal on allowed and denied rows" do
      member = user!()
      outsider = user!()

      external = user!()

      tenant =
        %Org{}
        |> Org.changeset(%{
          name: "T",
          slug: "t_#{System.unique_integer([:positive])}",
          parent_org_id: Tenancy.get_org_by_slug!("acme").id
        })
        |> Repo.insert!()

      {:ok, _} = Tenancy.mark_membership_external(%{user_id: external.id, org_id: tenant.id})

      home = channel!()
      elsewhere = channel!()
      p_member = seat!(home, member)
      _ = seat!(home, external)
      p_out = seat!(elsewhere, outsider)

      in_home = attachment!(%{space_id: home.id})

      dead_msg = post!(home, p_member, "soon gone")
      on_deleted = attachment!(%{space_id: home.id, message_id: dead_msg.id})

      Repo.update_all(from(m in Message, where: m.id == ^dead_msg.id),
        set: [deleted_at: DateTime.utc_now()]
      )

      legacy = attachment!(%{content_type: "image/jpeg", filename: "l.jpg"})
      other_space = attachment!(%{space_id: elsewhere.id})

      rows = [in_home, on_deleted, legacy, other_space]
      link_text = Enum.map_join(rows, "\n", &"/chat/attachments/#{&1.id}")
      msg = post!(elsewhere, p_out, link_text)

      decisions =
        for viewer <- [member, outsider, external], att <- rows do
          principal = {:user, viewer.id}
          batch = AttachmentLinks.resolve_for_viewer([msg], principal) |> Map.get(msg.id, [])
          single = Chat.get_visible_attachment_for_principal(att.id, principal)

          assert Enum.any?(batch, &(&1.id == att.id)) == not is_nil(single),
                 "viewer #{viewer.email} attachment #{att.filename}/#{att.id}"

          {viewer.id, att.id, not is_nil(single)}
        end

      # Both outcomes are exercised, so equality is not vacuous.
      assert {member.id, in_home.id, true} in decisions
      assert {outsider.id, in_home.id, false} in decisions
      assert {member.id, on_deleted.id, false} in decisions
      assert {external.id, legacy.id, false} in decisions
      assert {member.id, legacy.id, true} in decisions
      assert {outsider.id, other_space.id, true} in decisions
    end

    test "a nil principal or link-less messages resolve to nothing" do
      viewer = user!()
      space = channel!()
      p = seat!(space, viewer)
      att = attachment!(%{space_id: space.id})
      msg = post!(space, p, "/chat/attachments/#{att.id}")

      assert AttachmentLinks.resolve_for_viewer([msg], nil) == %{}
      assert AttachmentLinks.resolve_for_viewer([%{id: "x", content: "no links"}], nil) == %{}
    end
  end

  describe "merge/2 and the bare-line rule" do
    test "real attachments first, unique by id" do
      a = %{id: "a"}
      b = %{id: "b"}

      assert AttachmentLinks.merge(%{"m" => [a]}, %{"m" => [b, a], "n" => [b]}) ==
               %{"m" => [a, b], "n" => [b]}
    end

    # Rung 13 stage 1: the bare-line rule moved into the one link parser
    # (`LinkTargets`), applied by `ContentRenderer.render_message/2`'s
    # `:cards` option. Same behaviour, now on the rendered html.
    test "a link alone on a line goes; one mid-sentence stays" do
      id = Ecto.UUID.generate()
      url = "#{origin()}/chat/attachments/#{id}"
      path = "/chat/attachments/#{id}"

      render = fn content, cards ->
        content
        |> Platform.Chat.ContentRenderer.render_message(cards: cards)
        |> Phoenix.HTML.safe_to_string()
      end

      stripped = render.("Three cuts.\n#{url}", [path])
      assert stripped =~ "Three cuts."
      refute stripped =~ id

      assert render.("[clip](/chat/attachments/#{id})", [path]) == ""
      assert render.("/chat/attachments/#{id}", [path]) == ""

      assert render.("watch #{url} now", [path]) =~ ~s(href="#{url}")
      assert render.("Three cuts.\n#{url}", []) =~ ~s(href="#{url}")
    end
  end
end
