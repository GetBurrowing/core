defmodule PlatformWeb.ChatLive.UploadDialogRemovedTest do
  @moduledoc """
  Regression guard for redesign rung 11 (task 01a1557a-9de3): the upload
  dialog ("Share Images") and its hard-coded "Tag an agent" chips are gone,
  with no alias, wrapper or compatibility path left behind. Attach is the
  composer's staged tray now, and agents are tagged with @ in the caption.

  The scan reads the source tree, so a stray reference anywhere in `lib/`
  or `assets/js` fails here even if no test renders it.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo

  @app_root Path.expand("../../../..", __DIR__)
  @roots ["lib", "assets/js", "assets/css", "test"]
  # This file holds the list as literals, so it is the one file not scanned.
  @self Path.expand(__ENV__.file)

  # `agent-chip` is matched as a whole class name: `transcript-agent-chip`
  # (the meeting transcript's agent badge) is a different thing.
  @gone [
    {"upload_dialog", ~r/upload_dialog/},
    {"upload-send-form", ~r/upload-send-form/},
    {"upload_toggle_agent", ~r/upload_toggle_agent/},
    {"upload_tagged_agents", ~r/upload_tagged_agents/},
    {"agent-chip", ~r/(?<![\w-])agent-chip/},
    {"Share Images", ~r/Share Images/},
    {"Tag an agent", ~r/Tag an agent/},
    {"UploadButton", ~r/UploadButton/},
    {"upload_send", ~r/upload_send/},
    {"upload_caption", ~r/upload_caption/},
    {"upload-dropzone", ~r/upload-dropzone/},
    {"upload-add-more", ~r/upload-add-more/},
    {"upload-thumb", ~r/upload-thumb/},
    {"upload-panel", ~r/upload-panel/},
    {"upload-backdrop", ~r/upload-backdrop/},
    {"drag-hint", ~r/drag-hint/}
  ]

  defp source_files do
    @roots
    |> Enum.flat_map(fn root ->
      Path.wildcard(Path.join([@app_root, root, "**", "*.{ex,exs,heex,js,mjs,css}"]))
    end)
    |> Enum.reject(&String.contains?(&1, "/node_modules/"))
    |> Enum.reject(&(Path.expand(&1) == @self))
  end

  defp hits(regex) do
    for path <- source_files(),
        {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        Regex.match?(regex, line),
        do: "#{Path.relative_to(path, @app_root)}:#{n}"
  end

  test "the scanner sees the tree (positive control)" do
    assert length(source_files()) > 100
    assert hits(~r/staged-tray/) != []
    assert hits(~r/stageFiles/) != []
    # Every root is read: css and test included.
    assert Enum.any?(source_files(), &String.ends_with?(&1, "assets/css/app.css"))
    assert Enum.any?(source_files(), &String.contains?(&1, "/test/platform_web/"))
    refute Enum.any?(source_files(), &(Path.expand(&1) == @self))
  end

  for {label, regex} <- @gone do
    test "no source under lib/, assets/ or test/ references #{label}" do
      assert hits(unquote(Macro.escape(regex))) == []
    end
  end

  # LiveView 1.1 has no fallback for an event nothing handles: ChatLive has no
  # catch-all `handle_event/3`, so the process exits with `:function_clause`
  # in `ChatLive.handle_event/3` and the client remounts. Nothing opens.
  for event <- ["upload_dialog_open", "upload_send", "upload_toggle_agent"] do
    test "the deleted #{event} event is unhandled", %{conn: conn} do
      user =
        Repo.insert!(%User{
          email: "unhandled_#{unquote(event)}@example.com",
          name: "Unhandled Event",
          oidc_sub: "oidc-unhandled-#{unquote(event)}"
        })

      conn = init_test_session(conn, current_user_id: user.id)
      {:ok, view, _html} = live(conn, ~p"/chat/general")
      Process.flag(:trap_exit, true)

      assert {{:function_clause,
               [{PlatformWeb.ChatLive, :handle_event, [unquote(event) | _], _} | _]}, _} =
               catch_exit(render_hook(view, unquote(event), %{"agent" => "beacon"}))
    end
  end

  test "the chat page renders no upload dialog drop zone", %{conn: conn} do
    user =
      Repo.insert!(%User{
        email: "dialog_removed@example.com",
        name: "Dialog Removed",
        oidc_sub: "oidc-dialog-removed"
      })

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, html} = live(conn, ~p"/chat/general")

    assert has_element?(view, "#compose-form")
    refute has_element?(view, "#upload-dropzone")
    refute html =~ "Share Images"
    refute html =~ "Tag an agent"
  end
end
