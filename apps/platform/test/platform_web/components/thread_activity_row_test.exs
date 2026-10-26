defmodule PlatformWeb.Components.ThreadActivityRowTest do
  @moduledoc """
  The thread-activity row's paint (task 01a174f5 stage 3, design canvas
  01a175ca): the classes the canvas names, straight quotes, the accessible
  name in both numbers, nothing that makes it a message, and the masked-name
  path through a real `/chat` LiveView.

  Every refute is paired with a presence from the same render, so a row that
  never rendered cannot pass. `LazyHTML.query/2` only.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias PlatformWeb.Components.ThreadActivityRow

  @source_path Path.expand(
                 "../../../lib/platform_web/components/thread_activity_row.ex",
                 __DIR__
               )

  @row_sel "[data-role=thread-activity-row]"

  defp row_map(overrides) do
    Map.merge(
      %{
        id: "t-1",
        thread_id: "t-1",
        parent_message_id: "p-1",
        new_count: 3,
        excerpt: "Release notes for the next build",
        parent_author: "Parent Author",
        replier_name: "Second",
        replier_avatar_url: nil,
        replier_avatar_seed: "seed-second",
        replier_agent?: false,
        replier_agent_slot: "blue"
      },
      overrides
    )
  end

  defp render_row(overrides \\ %{}) do
    render_component(&ThreadActivityRow.row/1,
      dom_id: "thread-activity-t-1",
      row: row_map(overrides)
    )
    |> LazyHTML.from_fragment()
  end

  defp render_summary(n) do
    render_component(&ThreadActivityRow.summary/1, overflow: n) |> LazyHTML.from_fragment()
  end

  defp classes(doc, sel) do
    doc
    |> LazyHTML.query(sel)
    |> LazyHTML.attribute("class")
    |> Enum.map(&String.split/1)
  end

  defp one_class_list(doc, sel) do
    assert [list] = classes(doc, sel), "expected exactly one #{sel}"
    list
  end

  describe "paint" do
    test "13px, no ground at rest, press base-200, hover only at lg, 44px below lg" do
      row = render_row() |> one_class_list(@row_sel)

      assert "text-[13px]" in row
      assert "min-h-11" in row
      assert "active:bg-base-200" in row
      assert "lg:hover:bg-base-200" in row
      # No ground at rest: no unprefixed bg- class, and no bare hover:.
      refute Enum.any?(row, &String.starts_with?(&1, "bg-"))
      refute Enum.any?(row, &String.starts_with?(&1, "hover:"))
      # No slide when the row moves.
      refute Enum.any?(row, &String.starts_with?(&1, "transition"))
      refute Enum.any?(row, &String.starts_with?(&1, "animate"))
    end

    test "the glyph and 'new replies to' are text-subtle; the count is the only emphasis" do
      doc = render_row()

      glyph = one_class_list(doc, "[data-role=thread-activity-glyph]")
      assert "text-subtle" in glyph
      assert "shrink-0" in glyph
      assert doc |> LazyHTML.query("[data-role=thread-activity-glyph]") |> LazyHTML.text() == "↳"

      label = one_class_list(doc, "[data-role=thread-activity-count]")
      assert "text-subtle" in label
      assert "shrink-0" in label

      number =
        one_class_list(
          doc,
          "[data-role=thread-activity-count] [data-role=thread-activity-number]"
        )

      assert ~w(text-base-content font-semibold tabular-nums) -- number == []

      # The count is the ONLY emphasis in the row.
      # (The avatar's own initials weight is the component's, not the row's.)
      others =
        ~w(thread-activity-row thread-activity-glyph thread-activity-count thread-activity-excerpt)
        |> Enum.map_join(", ", &"[data-role=#{&1}][class*=font-]")

      assert doc |> LazyHTML.query(others) |> Enum.count() == 0

      assert doc
             |> LazyHTML.query("[data-role=thread-activity-count]")
             |> LazyHTML.text() == "3 new replies to"
    end

    test "the excerpt truncates first, in straight double quotes, base-content regular" do
      doc = render_row()
      excerpt = one_class_list(doc, "[data-role=thread-activity-excerpt]")
      assert ~w(min-w-0 truncate text-base-content) -- excerpt == []
      refute Enum.any?(excerpt, &String.starts_with?(&1, "font-"))
      refute "shrink-0" in excerpt

      text = doc |> LazyHTML.query("[data-role=thread-activity-excerpt]") |> LazyHTML.text()
      assert text == ~s("Release notes for the next build")
      refute text =~ ~r/[\x{201C}\x{201D}]/u
    end

    test "the avatar is the 20px existing component, protected from shrinking" do
      doc = render_row()
      wrap = one_class_list(doc, "[data-role=thread-activity-avatar]")
      assert "shrink-0" in wrap

      circle =
        one_class_list(doc, "[data-role=thread-activity-avatar] [data-avatar-kind=human] > div")

      assert "size-5" in circle

      assert doc
             |> LazyHTML.query("[data-role=thread-activity-avatar] [data-avatar-kind=human]")
             |> LazyHTML.attribute("title") == ["Second"]
    end

    test "an agent replier keeps its accent ring" do
      doc =
        render_row(%{replier_agent?: true, replier_name: "Helper", replier_agent_slot: "teal"})

      assert doc
             |> LazyHTML.query("[data-role=thread-activity-avatar]")
             |> LazyHTML.attribute("data-agent-slot") == ["teal"]

      assert "msg-agent-avatar" in one_class_list(doc, "[data-avatar-kind=agent]")

      # Control: a human replier carries no slot and no ring.
      human = render_row()

      assert human
             |> LazyHTML.query("[data-role=thread-activity-avatar][data-agent-slot]")
             |> Enum.count() == 0

      assert human |> LazyHTML.query(".msg-agent-avatar") |> Enum.count() == 0
    end

    test "the summary uses the same type and indent" do
      row = render_row() |> one_class_list(@row_sel)
      doc = render_summary(2)
      [phone, desk] = classes(doc, "[data-role=thread-activity-summary] button")

      shared = row -- ["flex"]
      assert shared -- phone == []
      assert shared -- desk == []
      assert "lg:hidden" in phone
      assert ~w(hidden lg:flex) -- desk == []

      assert doc
             |> LazyHTML.query("[data-role=thread-activity-summary] button.lg\\:hidden")
             |> LazyHTML.text() =~ "2 more threads with new replies"
    end
  end

  describe "a pointer, not a message" do
    test "announced as a link with the accessible name, singular and plural" do
      plural = render_row()
      assert LazyHTML.attribute(LazyHTML.query(plural, @row_sel), "role") == ["link"]
      assert LazyHTML.attribute(LazyHTML.query(plural, @row_sel), "tabindex") == ["0"]
      assert LazyHTML.attribute(LazyHTML.query(plural, @row_sel), "phx-key") == ["Enter"]

      assert LazyHTML.attribute(LazyHTML.query(plural, @row_sel), "aria-label") == [
               "3 new replies in thread: Release notes for the next build. Latest from Second."
             ]

      single = render_row(%{new_count: 1})

      assert LazyHTML.attribute(LazyHTML.query(single, @row_sel), "aria-label") == [
               "1 new reply in thread: Release notes for the next build. Latest from Second."
             ]

      assert single |> LazyHTML.query("[data-role=thread-activity-count]") |> LazyHTML.text() ==
               "1 new reply to"
    end

    test "no time, no reactions, no menu, no message gesture hook" do
      doc = render_row()
      assert doc |> LazyHTML.query(@row_sel) |> Enum.count() == 1

      assert doc |> LazyHTML.query("time") |> Enum.count() == 0
      assert doc |> LazyHTML.query("[datetime]") |> Enum.count() == 0
      assert doc |> LazyHTML.query("[phx-hook]") |> Enum.count() == 0

      assert doc
             |> LazyHTML.query(".reaction-row, .message-pill, [data-message-id]")
             |> Enum.count() == 0

      assert doc |> LazyHTML.query("button, [aria-haspopup]") |> Enum.count() == 0
    end
  end

  describe "source guard" do
    test "no hex and no bare hover: in thread_activity_row.ex" do
      src = File.read!(@source_path)
      # Positive controls: the reader really is looking at the painted file.
      assert src =~ "lg:hover:bg-base-200"
      assert src =~ "text-subtle"

      refute src =~ ~r/#[0-9a-fA-F]{3,8}\b/
      refute src =~ ~r/(?<![\w:-])hover:/
      refute src =~ ~r/\btext-(?!subtle\b|base-content\b|left\b|center\b|\[13px\])[a-z]/
    end
  end

  describe "masked names (through a real LiveView)" do
    setup %{conn: conn} do
      n = System.unique_integer([:positive])

      viewer_user =
        Repo.insert!(%User{
          email: "tar_viewer_#{n}@example.com",
          name: "Row Viewer",
          oidc_sub: "oidc-tar-viewer-#{n}"
        })

      # The account name is what must NOT surface; the space's label for
      # this participant is what the log shows everywhere else.
      other_user =
        Repo.insert!(%User{
          email: "tar_other_#{n}@example.com",
          name: "Account Name Unshown",
          oidc_sub: "oidc-tar-other-#{n}"
        })

      {:ok, space} =
        Chat.create_space(%{name: "Row paint", slug: "row-paint-#{n}", kind: "channel"})

      member = fn user, label ->
        {:ok, p} =
          Chat.add_participant(space.id, %{
            participant_type: "user",
            participant_id: user.id,
            display_name: label,
            joined_at: DateTime.add(DateTime.utc_now(), -3600, :second)
          })

        p
      end

      viewer = member.(viewer_user, "Row Viewer")
      other = member.(other_user, "Shown Label")

      %{
        conn: init_test_session(conn, current_user_id: viewer_user.id),
        space: space,
        viewer: viewer,
        other: other
      }
    end

    test "the accessible name and the avatar use the log's label, never the account name", ctx do
      {:ok, parent} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.viewer.id,
          content_type: "text",
          content: "Masked parent"
        })

      {:ok, thread} = Chat.create_thread_for_message(ctx.space.id, parent.id)
      {:ok, _} = Chat.reply_to_thread(thread.id, ctx.viewer.id, %{content: "seed"})

      {:ok, view, _} = live(ctx.conn, ~p"/chat/#{ctx.space.slug}")
      {:ok, _} = Chat.reply_to_thread(thread.id, ctx.other.id, %{content: "from the other"})

      row = view |> render() |> LazyHTML.from_document() |> LazyHTML.query(@row_sel)
      assert Enum.count(row) == 1

      assert LazyHTML.attribute(row, "aria-label") == [
               "1 new reply in thread: Masked parent. Latest from Shown Label."
             ]

      assert row
             |> LazyHTML.query("[data-role=thread-activity-avatar] [title]")
             |> LazyHTML.attribute("title") == ["Shown Label"]

      refute LazyHTML.to_html(row) =~ "Account Name Unshown"
    end
  end
end
