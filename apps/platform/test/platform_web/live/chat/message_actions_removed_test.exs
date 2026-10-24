defmodule PlatformWeb.ChatLive.MessageActionsRemovedTest do
  @moduledoc """
  Redesign rung 9 (task 01a1557a-9406) deleted, in place, every older
  message-action surface: the desktop hover row, the left-gutter reply, the
  agent header "Context" button and the dead long-press lift pill with its
  events, assign and hook. The tap pill replaced them. This scan keeps them
  deleted: no alias, shim or second path may bring a name back.

  Each stage of rung 9 extends `@gone`.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  # Stage 2 (the 'Message' sheet re-skin) added the old sheet's row labels:
  # "What this message is answering" became "What this is answering", and
  # "Pin / Unpin" became "Pin message" / "Unpin message".
  #
  # Stage 3 (reactions and inline threads) deleted the thread side panel no
  # template rendered: its events, assigns and reset helper. The event name
  # `open_thread` is matched QUOTED, so `open_inline_thread`,
  # `expand_inline_thread` and `space_sheet_open_thread` do not hit; and
  # "▲ Collapse thread" became the masters' "collapse".
  #
  # Stage 4 (edit guard and version history) deleted the custom removal
  # modal and all of its plumbing (the native confirm in MessageEditor
  # replaced it), the centred version-history overlay and its 'Edit history'
  # title (now the 'Version history' sheet and popover), and swept the
  # last dead add-reaction CSS.
  @gone [
    "longpress_menu",
    "LongpressMenu",
    "MessageLift",
    "message_lift",
    "longpress-pill",
    "longpress-scrim",
    "open_longpress_menu",
    "longpress_menu_for",
    "message-action-row",
    "msg-reply-gutter",
    "message-context-trigger",
    "What this message is answering",
    "Pin / Unpin",
    "close_thread",
    "send_thread_message",
    "active_thread",
    "reset_thread_panel",
    "thread_attachments_map",
    ~s("open_thread"),
    "Collapse thread",
    "pending_save_edit",
    "confirm_save_edit",
    "cancel_save_edit",
    "edit_removal_warning",
    "edit-removal-warning",
    "removes_content",
    "shortenedOrRemoved",
    "chat-version-history-overlay",
    "Edit history",
    "reaction-add-btn"
  ]

  defp sources do
    for dir <- ["lib", "assets/js", "assets/css"],
        path <- Path.wildcard(Path.join([@root, dir, "**", "*.{ex,exs,heex,js,mjs,css}"])),
        not String.contains?(path, "/node_modules/"),
        do: path
  end

  defp hits(needle) do
    for path <- sources(),
        {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        String.contains?(line, needle),
        do: "#{Path.relative_to(path, @root)}:#{n}"
  end

  test "the scan covers the tree it claims to" do
    paths = sources()
    assert Enum.any?(paths, &String.ends_with?(&1, "lib/platform_web/components/chat_message.ex"))
    assert Enum.any?(paths, &String.ends_with?(&1, "assets/js/hooks/message_gestures.js"))
    assert Enum.any?(paths, &String.ends_with?(&1, "assets/css/app.css"))
  end

  test "positive control: the pill that replaced them is found" do
    assert hits("message-pill") != []
    assert hits("MessageGestures") != []
    assert hits("What this is answering") != []
    assert hits("open_inline_thread") != []
    assert hits("removesMost") != []
    assert hits("version-history-sheet") != []
  end

  for needle <- @gone do
    test "no source under lib, assets/js or assets/css names #{needle}" do
      assert hits(unquote(needle)) == []
    end
  end
end
