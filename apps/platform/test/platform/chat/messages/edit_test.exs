defmodule Platform.Chat.Messages.EditTest do
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Messages.Edit
  alias Platform.Chat.{MessageVersions, PubSub}

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp create_space! do
    slug = "edit-space-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, space} = Chat.create_space(%{name: "Edit Test", slug: slug, kind: "channel"})
    space
  end

  defp add_participant!(space_id, display_name \\ "Alice") do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now(),
        display_name: display_name
      })

    p
  end

  defp post_message!(space_id, participant_id, content \\ "original content") do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: content
      })

    MessageVersions.record_v1!(msg)
    msg
  end

  # ── apply_edit/3 ─────────────────────────────────────────────────────────

  describe "apply_edit/3" do
    test "updates content, sets edited_at, appends v2 row, broadcasts :message_edited" do
      space = create_space!()
      p = add_participant!(space.id, "Alice")
      msg = post_message!(space.id, p.id, "original content")

      :ok = PubSub.subscribe(space.id)

      assert {:ok, updated} = Edit.apply_edit(msg, p, "edited body")
      assert updated.content == "edited body"
      refute is_nil(updated.edited_at)

      # V2 row appended.
      assert [%{version_number: 2, content: "edited body"}, %{version_number: 1}] =
               MessageVersions.list_versions(msg.id)

      # Broadcast received with the full payload.
      assert_received {:message_edited, payload}
      assert payload.message.id == msg.id
      assert payload.previous_content == "original content"
      assert payload.version_number == 2
      assert payload.edited_by_participant_id == p.id
    end

    test "returns {:error, :frozen, freezing_action} with participant_display_name" do
      space = create_space!()
      author = add_participant!(space.id, "Alice")
      freezer = add_participant!(space.id, "Saru")
      msg = post_message!(space.id, author.id, "original content")

      {:ok, frozen_msg} = MessageVersions.freeze(msg, freezer.id)

      assert {:error, :frozen, freezing_action} =
               Edit.apply_edit(frozen_msg, author, "new content")

      assert freezing_action.participant_id == freezer.id
      assert freezing_action.participant_display_name == "Saru"
      refute is_nil(freezing_action.frozen_at)
    end

    test "does not broadcast when the edit fails" do
      space = create_space!()
      author = add_participant!(space.id, "Alice")
      freezer = add_participant!(space.id, "Saru")
      msg = post_message!(space.id, author.id, "original content")

      :ok = PubSub.subscribe(space.id)

      {:ok, frozen_msg} = MessageVersions.freeze(msg, freezer.id)
      {:error, :frozen, _} = Edit.apply_edit(frozen_msg, author, "new content")

      refute_received {:message_edited, _}
    end
  end

  # ── compute_removed_substrings/2 ─────────────────────────────────────────

  describe "compute_removed_substrings/2" do
    test "lists contiguous runs of words present in previous but missing from new" do
      assert ["support@example.com"] =
               Edit.compute_removed_substrings(
                 "please contact support@example.com for help",
                 "please contact for help"
               )
    end

    test "returns [] when content is unchanged" do
      assert [] = Edit.compute_removed_substrings("same words", "same words")
    end

    test "returns [] when content is purely added to" do
      assert [] =
               Edit.compute_removed_substrings(
                 "original",
                 "original plus some new stuff"
               )
    end

    test "groups multi-word runs together" do
      assert ["leaked secret token"] =
               Edit.compute_removed_substrings(
                 "the leaked secret token is here",
                 "the is here"
               )
    end

    test "handles empty previous content gracefully" do
      assert [] = Edit.compute_removed_substrings("", "hello world")
    end
  end

  # ── Policy 1 per-participant fan-out (task 019e1e83 Stage 2) ─────────────

  describe "apply_edit/3 — Policy 1 per-participant fan-out" do
    test "broadcasts {:message_edited, _} on chat:participant:<id> for each entitled recipient" do
      space = create_space!()
      alice = add_participant!(space.id, "Alice")
      msg = post_message!(space.id, alice.id, "hey @[Alice] take a look")

      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, "chat:participant:" <> alice.id)

      assert {:ok, _} = Edit.apply_edit(msg, alice, "hey @[Alice] take a look now")

      assert_receive {:message_edited, payload}, 1_000
      assert payload.message.id == msg.id
      assert payload.edited_by_participant_id == alice.id
    end

    test "does NOT broadcast on chat:participant:<id> for non-entitled participants" do
      space = create_space!()
      alice = add_participant!(space.id, "Alice")
      bob = add_participant!(space.id, "Bob")
      msg = post_message!(space.id, alice.id, "hey @[Alice] take a look")

      :ok = Phoenix.PubSub.subscribe(Platform.PubSub, "chat:participant:" <> bob.id)

      assert {:ok, _} = Edit.apply_edit(msg, alice, "hey @[Alice] take a look now")

      refute_receive {:message_edited, _}, 200
    end

    test "still broadcasts on the space topic even when no per-participant recipients match" do
      space = create_space!()
      alice = add_participant!(space.id, "Alice")
      msg = post_message!(space.id, alice.id, "daily standup notes")

      :ok = PubSub.subscribe(space.id)

      assert {:ok, _} = Edit.apply_edit(msg, alice, "daily standup notes draft")

      assert_receive {:message_edited, _payload}, 1_000
    end
  end
end
