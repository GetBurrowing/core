defmodule PlatformWeb.ChatLive.AgentsMembersSheetsRemovedTest do
  @moduledoc """
  Rung 8 (task 01a1557a-8f80) replaced three surfaces with the Agents and
  Members sheets: the header agent eye (stage 2), and the utility bar's
  agents dropdown ("N/M agents", its panel and hover-only Remove) and people
  online badge and panel (stage 3). This file proves they left nothing
  behind. It is stage 3's `utility_bar_roster_removed_test.exs`, renamed in
  place and widened by stage 4.

  Three halves:

    1. A source scan of `apps/platform/lib`, `assets/js`, `assets/css` and
       `test` (this file excepted: it holds the literal list) for every name
       the deleted surfaces used. Stage 3's own extra names (assigns of the
       deleted shell meter) are scanned in `lib` only, as stage 3 did, because
       `presence_hooks_test.exs` still names them to refute them as assigns.
    2. The rendered page: `/chat` and `/tasks` carry no roster button or
       presence badge, and a space with agents carries no eye.
    3. The deleted events: what LiveView does when a client still sends one.

  ## Narrowed patterns and one stated exclusion

    * `dismiss_agent` is scanned as the quoted event name `"dismiss_agent"`.
      `Platform.Meetings.dismiss_agent/2` (meetings.ex) removes an agent from
      a meeting room and was never part of these surfaces.
    * `principal_name` is scanned as a whole word, so
      `Chat.agent_principal_name/1` (the live agent display-name lookup) does
      not match.
    * `watch_enabled` is excluded from `priv/repo/migrations` (not scanned)
      and from `test/platform/chat/agent_attention_controls_test.exs`, whose
      migration test rolls the rename back and inserts rows through the
      pre-migration column by its name. Both are the column's history, not a
      live reference.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  @app Path.expand("../../../..", __DIR__)
  @this_file Path.expand(__ENV__.file)

  @roots ["lib", "assets/js", "assets/css", "test"]

  # {label, regex, paths excluded beyond this file (relative to apps/platform)}
  @forbidden [
    {"agent-eye", ~r/agent-eye/, []},
    {"active_agent_arm", ~r/active_agent_arm/, []},
    {"active_agent_clear", ~r/active_agent_clear/, []},
    {"ActiveAgentHooks", ~r/ActiveAgentHooks/, []},
    {"watch_enabled", ~r/watch_enabled/,
     ["test/platform/chat/agent_attention_controls_test.exs"]},
    {"toggle_roster", ~r/toggle_roster/, []},
    {"shell-roster", ~r/shell-roster/, []},
    {"toggle_presence_panel", ~r/toggle_presence_panel/, []},
    {"shell-presence", ~r/shell-presence/, []},
    {~s("dismiss_agent"), ~r/"dismiss_agent"/, []},
    {"Agent roster", ~r/Agent roster/, []},
    {"Online participants", ~r/Online participants/, []}
  ]

  # Stage 3's names for the deleted shell meter's assigns, in lib only.
  @forbidden_in_lib [
    {"roster_open", ~r/roster_open/},
    {"show_presence_panel", ~r/show_presence_panel/},
    {"principal_name", ~r/\bprincipal_name\b/},
    {"roster_items", ~r/roster_items/}
  ]

  defp sources(roots) do
    roots
    |> Enum.flat_map(&Path.wildcard(Path.join([@app, &1, "**", "*.{ex,exs,heex,js,mjs,ts,css}"])))
    |> Enum.reject(&String.contains?(&1, "/node_modules/"))
    |> Enum.reject(&(Path.expand(&1) == @this_file))
  end

  defp hits(regex, roots, excluded \\ []) do
    for path <- sources(roots),
        rel = Path.relative_to(path, @app),
        rel not in excluded,
        {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        Regex.match?(regex, line),
        do: "#{rel}:#{n}: #{String.trim(line)}"
  end

  describe "source sweep" do
    test "lib, assets/js, assets/css and test carry no name of the deleted surfaces" do
      # Positive controls: every root is read, and the scanner finds a name that
      # IS there, so the zeros below are not a scanner that finds nothing.
      for root <- @roots, do: assert(sources([root]) != [], "read nothing under #{root}")
      assert length(sources(["lib"])) > 100
      assert hits(~r/agents-sheet/, ["lib"]) != []
      assert hits(~r/agents-sheet/, ["test"]) != []
      assert hits(~r/members-sheet/, ["lib"]) != []

      # The exclusion is not hiding a scanner that cannot see the file.
      assert hits(~r/watch_enabled/, ["test"]) != []

      failures =
        for {label, regex, excluded} <- @forbidden,
            (found = hits(regex, @roots, excluded)) != [],
            do: "#{label}:\n  " <> Enum.join(found, "\n  ")

      assert failures == [], "deleted names are still referenced:\n" <> Enum.join(failures, "\n")
    end

    test "lib carries no assign of the deleted shell meter" do
      failures =
        for {label, regex} <- @forbidden_in_lib,
            (found = hits(regex, ["lib"])) != [],
            do: "#{label}:\n  " <> Enum.join(found, "\n  ")

      assert failures == [], Enum.join(failures, "\n")
    end
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "bar-#{n}@example.com",
      name: "Bar Viewer #{n}",
      oidc_sub: "oidc-bar-#{n}"
    })
  end

  defp channel_with_agent! do
    user = user!()

    {:ok, space} =
      Chat.create_channel(%{
        name: "Bar Room",
        slug: "bar-room-#{System.unique_integer([:positive])}",
        created_by: user.id
      })

    {:ok, agent} =
      Repo.insert(%Platform.Agents.Agent{
        slug: "bar-agent-#{System.unique_integer([:positive])}",
        name: "Bar Agent",
        status: "active"
      })

    {:ok, _} = Chat.set_principal_agent(space.id, agent.id)
    %{user: user, space: space}
  end

  describe "rendered page" do
    test "/chat and /tasks render no agents dropdown, no people-online badge and no eye", %{
      conn: conn
    } do
      %{user: user, space: space} = channel_with_agent!()
      conn = init_test_session(conn, current_user_id: user.id)

      for path <- [~p"/chat/#{space.slug}", ~p"/tasks"] do
        {:ok, view, _html} = live(conn, path)
        _ = render_async(view)
        html = render(view)

        # Positive control: the shell chrome itself rendered (the phone top
        # strip, renamed from the utility bar by Burrow redesign 22, and the
        # desktop sidebar's user row, which replaced the account menu).
        assert has_element?(view, "#phone-top-bar"), "no top strip on #{path}"
        assert has_element?(view, "#sidebar #sidebar-user")

        refute has_element?(view, "[data-test-id=shell-roster-button]")
        refute has_element?(view, "[data-test-id=shell-presence-badge]")
        refute html =~ "shell-agents-ratio"
        refute html =~ ~s(phx-click="toggle_roster")
        refute html =~ ~s(phx-click="toggle_presence_panel")
        refute has_element?(view, "[data-role=agent-eye]")
      end

      # Positive control for the eye refute: the space has an agent, so its
      # replacement entry renders: the details panel's Agents row (the
      # header button until Burrow redesign 22 stage 4).
      {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
      render_click(view, "details_open", %{"page" => "space"})
      assert has_element?(view, "#details-panel [data-role=details-agents]")
    end
  end

  # No clause handles these events any more. ChatLive has no `handle_event/3`
  # catch-all and the shell's `attach_hook` handlers `{:cont, _}` events they
  # do not own, so the event reaches `ChatLive.handle_event/3` with no
  # matching clause: the LiveView process crashes with `:function_clause`
  # (in `PlatformWeb.ChatLive.handle_event/3`, the event's own name and
  # params in the frame) and `render_hook/3` exits with it. In a browser that is a crash and
  # remount (the client rejoins and the page re-renders), never a silent
  # write.
  describe "deleted events" do
    for event <- ["active_agent_arm", "toggle_roster"] do
      test "#{event} is unhandled: ChatLive crashes with function_clause", %{conn: conn} do
        %{user: user, space: space} = channel_with_agent!()
        conn = init_test_session(conn, current_user_id: user.id)
        {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
        Process.flag(:trap_exit, true)
        ref = Process.monitor(view.pid)

        {reason, _} = catch_exit(render_hook(view, unquote(event), %{}))

        assert {:function_clause,
                [{PlatformWeb.ChatLive, :handle_event, [unquote(event), %{}, _socket], _} | _]} =
                 reason

        assert_receive {:DOWN, ^ref, :process, _, _}
      end
    end
  end
end
