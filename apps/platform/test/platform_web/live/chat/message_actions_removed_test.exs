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

  # The tree is walked and read once per module: each of the ~36 tests
  # re-reading all of lib and assets timed one out at 60 s inside File.read!
  # in an unsharded hosted run (40425309132).
  setup_all do
    %{corpus: Enum.map(sources(), &{Path.relative_to(&1, @root), File.read!(&1)})}
  end

  defp sources do
    for dir <- ["lib", "assets/js", "assets/css"],
        path <- Path.wildcard(Path.join([@root, dir, "**", "*.{ex,exs,heex,js,mjs,css}"])),
        not String.contains?(path, "/node_modules/"),
        do: path
  end

  defp hits(corpus, needle) do
    # A whole-file match first; only a file that hits is split into lines.
    for {rel, content} <- corpus,
        String.contains?(content, needle),
        {line, n} <- content |> String.split("\n") |> Enum.with_index(1),
        String.contains?(line, needle),
        do: "#{rel}:#{n}"
  end

  test "the scan covers the tree it claims to", %{corpus: corpus} do
    paths = Enum.map(corpus, &elem(&1, 0))
    assert "lib/platform_web/components/chat_message.ex" in paths
    assert "assets/js/hooks/message_gestures.js" in paths
    assert "assets/css/app.css" in paths
  end

  test "positive control: the pill that replaced them is found", %{corpus: corpus} do
    assert hits(corpus, "message-pill") != []
    assert hits(corpus, "MessageGestures") != []
    assert hits(corpus, "What this is answering") != []
    assert hits(corpus, "open_inline_thread") != []
    assert hits(corpus, "removesMost") != []
    assert hits(corpus, "version-history-sheet") != []
  end

  for needle <- @gone do
    test "no source under lib, assets/js or assets/css names #{needle}", %{corpus: corpus} do
      assert hits(corpus, unquote(needle)) == []
    end
  end
end
