defmodule Platform.Chat.SpaceAddressingTest do
  @moduledoc """
  Coverage for the chat URL addressing PAIR (task 019fabe8 stage 4):

    * `Chat.space_path_segment/1` — how a space is written into a `/chat/...`
      url. THE single definition; `PlatformWeb.ChatLive.space_nav_target/1`
      delegates to it and the @mention inbox producer calls it directly.
    * `Chat.space_for_path_segment/1` — the inverse, used by the inbox to turn
      a stored segment back into a human label.

  The bug that motivated these: the inbox producer interpolated `space.slug`
  raw while the sidebar rail routed org-scoped spaces by ID. Two rules, one
  URL space. A DM has NO slug (`create_dm_space/3` inserts none), so its
  mention url was literally `"/chat/?message=<uuid>"` — a route miss that
  dumped the reader in their first channel.

  These are unit + round-trip tests. The end-to-end shape (an actual emitted
  inbox row per space kind) lives in `Platform.Chat.MentionInboxTest`.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures, only: [acme_org_id: 0]

  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Repo

  defp unique_slug, do: "addressing-#{System.unique_integer([:positive])}"

  defp create_space!(attrs) do
    {:ok, space} =
      Chat.create_space(
        Map.merge(%{name: "Space #{System.unique_integer([:positive])}", kind: "channel"}, attrs)
      )

    space
  end

  defp space_count, do: Repo.aggregate(Space, :count, :id)

  describe "space_path_segment/1 (unit)" do
    test "org-scoped space addresses by id even though it has a slug" do
      space = %{org_id: "org-uuid", id: "space-uuid", slug: "general"}
      assert Chat.space_path_segment(space) == "space-uuid"
    end

    test "org-less space with a slug keeps the shareable slug" do
      assert Chat.space_path_segment(%{org_id: nil, id: "space-uuid", slug: "announcements"}) ==
               "announcements"
    end

    test "org-less space with NO slug (the DM shape) addresses by id" do
      assert Chat.space_path_segment(%{org_id: nil, id: "space-uuid", slug: nil}) == "space-uuid"
    end

    test "never returns an empty segment for any shape" do
      # The pre-fix failure mode was an EMPTY segment ("/chat/?message=..."),
      # so assert the negative directly rather than only asserting the happy
      # values above.
      for space <- [
            %{org_id: nil, id: "i", slug: nil},
            %{org_id: nil, id: "i", slug: ""},
            %{id: "i", slug: nil},
            %{id: "i"}
          ] do
        segment = Chat.space_path_segment(space)
        assert is_binary(segment)
        assert segment != "", "empty segment for #{inspect(space)} would miss /chat/:space_slug"
      end
    end

    test "tolerates a plain map without :org_id (older fixtures)" do
      assert Chat.space_path_segment(%{id: "x", slug: "y"}) == "y"
      assert Chat.space_path_segment(%{id: "x"}) == "x"
    end
  end

  describe "space_path_segment/1 -> space_for_path_segment/1 round trip" do
    test "org-scoped channel" do
      space = create_space!(%{slug: unique_slug(), org_id: acme_org_id()})

      segment = Chat.space_path_segment(space)
      assert segment == space.id

      assert %Space{id: id} = Chat.space_for_path_segment(segment)
      assert id == space.id
    end

    test "org-less channel" do
      space = create_space!(%{slug: unique_slug()})

      segment = Chat.space_path_segment(space)
      assert segment == space.slug

      assert %Space{id: id} = Chat.space_for_path_segment(segment)
      assert id == space.id
    end

    test "DM (no slug at all)" do
      dm = create_space!(%{kind: "dm", name: nil, slug: nil, is_direct: true})
      assert is_nil(dm.slug)

      segment = Chat.space_path_segment(dm)
      assert segment == dm.id

      assert %Space{id: id} = Chat.space_for_path_segment(segment)
      assert id == dm.id
    end

    test "group (no slug at all)" do
      group = create_space!(%{kind: "group", name: nil, slug: nil})

      segment = Chat.space_path_segment(group)
      assert %Space{id: id} = Chat.space_for_path_segment(segment)
      assert id == group.id
    end
  end

  describe "space_for_path_segment/1 refuses to create" do
    test "an unknown channel-shaped slug resolves to nil and mints nothing" do
      before = space_count()

      # `bootstrap_space/2` in ChatLive would happily create a channel from
      # this exact string. The resolver must not.
      assert Chat.space_for_path_segment("some-plausible-channel") == nil
      assert space_count() == before
    end

    test "an unknown uuid resolves to nil" do
      assert Chat.space_for_path_segment(Ecto.UUID.generate()) == nil
    end

    test "nil, empty and non-binary segments resolve to nil without raising" do
      assert Chat.space_for_path_segment(nil) == nil
      assert Chat.space_for_path_segment("") == nil
      assert Chat.space_for_path_segment(:atom) == nil
    end

    test "a 16-character slug does not reach Repo.get as a raw binary uuid" do
      # `Platform.UUID.valid?/1` rather than a bare `Ecto.UUID.cast/1`: a bare
      # cast accepts ANY 16-byte binary, so a 16-character slug cleared the
      # guard and raised inside Repo (the PR #613 family). Pin it here too —
      # this resolver makes the same branch decision ChatLive does.
      slug = "sixteen-chars-yy"
      assert String.length(slug) == 16
      space = create_space!(%{slug: slug})

      assert %Space{id: id} = Chat.space_for_path_segment(slug)
      assert id == space.id
    end
  end
end
