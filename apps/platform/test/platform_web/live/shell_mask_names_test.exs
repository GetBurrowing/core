defmodule PlatformWeb.ShellMaskNamesTest do
  @moduledoc """
  Task 01a1600d stage 1: the shell carries the screen-share mask state on
  every page, and every web write of it goes through
  `PlatformWeb.ShellLive.put_mask_names/2`.

  The shell's assigns are read through `:sys.get_state(view.pid).socket.assigns`,
  the LiveView channel process's own socket. That is the socket the shell's
  on_mount and `:drawer_events` hook write, and the one stage 2's chip will
  render from; nothing renders these assigns yet in this stage.

  Every refute of a real name has an unmasked control in the same test that
  asserts the name IS there, so a refute cannot pass against an empty render.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.MaskAssertions

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.{Repo, Tasks, Tenancy}
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.ShellLive

  @chat_orgs ["Vandelay-Ind", "Globex", "Initech"]
  @tenants ~w(initech vandelay_ind globex)
  @machine_attrs ~w(value)
  @twelve_hours 12 * 3600

  defp insert_user(tag, member? \\ false) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "shell-mask-#{tag}-#{n}@example.com",
        name: "Shell Mask #{tag} #{n}",
        oidc_sub: "oidc-shell-mask-#{tag}-#{n}"
      })

    if member? do
      Enum.each(Tenancy.list_orgs(), fn org ->
        role = if org.slug == "acme", do: "admin", else: "member"

        %OrgMembership{}
        |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
        |> Repo.insert!()
      end)
    end

    user
  end

  defp conn_for(user), do: init_test_session(build_conn(), current_user_id: user.id)

  defp follow(conn, path) do
    case live(conn, path) do
      {:error, {:live_redirect, %{to: to}}} -> live(conn, to)
      ok -> ok
    end
  end

  defp mount!(user, path) do
    {:ok, view, html} = follow(conn_for(user), path)
    {view, html}
  end

  defp shell(view), do: :sys.get_state(view.pid).socket.assigns

  defp set_until(user, %DateTime{} = until) do
    stored = Repo.get!(User, user.id)

    stored
    |> User.changeset(%{
      preferences:
        Map.put(stored.preferences || %{}, "mask_names_until", DateTime.to_iso8601(until))
    })
    |> Repo.update!()
  end

  defp stored_until(user), do: Accounts.mask_names_until(Accounts.get_user(user.id))

  defp seed_projects do
    for {slug, name} <- [
          {"initech", "Initech Storefront"},
          {"vandelay_ind", "Vandelay-Ind Rollout"},
          {"globex", "Globex Onboarding"}
        ] do
      {:ok, project} =
        Tasks.create_project(%{
          name: name,
          slug: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-"),
          org_id: Tenancy.get_org_by_slug!(slug).id
        })

      project
    end
  end

  defp tasks_names(projects),
    do:
      Enum.map(@tenants, &Tenancy.get_org_by_slug!(&1).name) ++
        @tenants ++ Enum.map(projects, & &1.name)

  # See mask_names_shared_test.exs: a stylesheet keyed on real slugs that
  # renders nothing on screen.
  defp without_scope_stylesheet(html),
    do: Regex.replace(~r/<style id="org-scope-colors"[^>]*>.*?<\/style>/s, html, "")

  # Every `UPDATE "users"` statement carrying this user's id while `fun` runs.
  # Telemetry handlers are global, so the id filter is what keeps a sibling
  # test's writes out of the count.
  defp count_user_updates(user, fun) do
    test_pid = self()
    ref = make_ref()
    handler_id = "shell-mask-updates-#{System.unique_integer([:positive])}"
    dumped = Ecto.UUID.dump!(user.id)

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :repo, :query],
        fn _event, _measurements, meta, _config ->
          query = Map.get(meta, :query) || ""
          params = Map.get(meta, :params) || []

          if String.starts_with?(query, ~s(UPDATE "users")) and
               Enum.any?(params, &(&1 == user.id or &1 == dumped)) do
            send(test_pid, {ref, :user_update})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain(ref, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  # Calls of `Platform.Accounts.put_mask_names/2` made by the LiveView process
  # while `fun` runs: the number of writes one event STARTED.
  #
  # WHY this and not only the UPDATE count above: the write is idempotent
  # within a second (off deletes a key that is then absent; on stores
  # now + 12h truncated to the second), and Ecto issues no UPDATE for a
  # changeset with no changes. So a second write in the same event is
  # invisible to the statement count by construction. Measured: probe (c),
  # the shell also writing for ChatLive, left the UPDATE count at 1.
  defp count_writes(view, fun) do
    mfa = {Accounts, :put_mask_names, 2}
    1 = :erlang.trace(view.pid, true, [:call, {:tracer, self()}])
    _ = :erlang.trace_pattern(mfa, true, [:global])

    try do
      result = fun.()
      {result, drain_calls(view.pid, 0)}
    after
      :erlang.trace_pattern(mfa, false, [:global])
      :erlang.trace(view.pid, false, [:call])
    end
  end

  defp drain_calls(pid, n) do
    receive do
      {:trace, ^pid, :call, {Accounts, :put_mask_names, [_, _]}} -> drain_calls(pid, n + 1)
    after
      100 -> n
    end
  end

  defp drain(ref, n) do
    receive do
      {^ref, :user_update} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end

  setup do
    {:ok, _} = Chat.create_space(%{name: "General", slug: "general", kind: "channel"})

    # Burrow redesign 22 stage 2 deleted the desktop channel rail, whose
    # section headers spelled every org on /chat. The Chat list has no org
    # headers, so one channel NAMED after each org carries the names into the
    # chat document, where the org-derived rule masks them.
    for name <- @chat_orgs do
      slug = String.downcase(name)
      org = Tenancy.get_org_by_slug(String.replace(slug, "-", "_"))

      {:ok, _} =
        Chat.create_space(%{name: name, slug: slug, kind: "channel", org_id: org && org.id})
    end

    :ok
  end

  describe "seed" do
    test "a stored mask seeds :mask_names? on every shell page; an unmasked user reads false" do
      masked = insert_user("seed-a")
      plain = insert_user("seed-b")
      set_until(masked, DateTime.add(DateTime.utc_now(), 3600, :second))

      for path <- ~w(/inbox /settings /meetings /chat) do
        {view, _} = mount!(masked, path)
        assigns = shell(view)
        assert assigns.mask_names? == true, "#{path}: expected masked"
        assert assigns.mask_chip_open == false
        assert Map.has_key?(assigns, :mask_zone)

        # Positive control: the same page for a user with no key reads false.
        {plain_view, _} = mount!(plain, path)
        assert shell(plain_view).mask_names? == false, "#{path}: expected unmasked"
      end
    end

    test "expiry by fixture: one second past reads false, a few seconds ahead reads true" do
      user = insert_user("expiry")

      set_until(user, DateTime.add(DateTime.utc_now(), -1, :second))
      {view, _} = mount!(user, "/inbox")
      refute shell(view).mask_names?

      # A few seconds rather than one, so a slow mount on a loaded rig cannot
      # cross the instant between the write and the mount's own clock read.
      set_until(user, DateTime.add(DateTime.utc_now(), 5, :second))
      {view, _} = mount!(user, "/inbox")
      assert shell(view).mask_names?
    end

    test ":mask_zone resolves the connect param's zone; an unknown zone is nil" do
      user = insert_user("zone")

      conn = conn_for(user) |> put_connect_params(%{"timezone" => "America/Chicago"})
      {:ok, view, _} = live(conn, "/inbox")
      assert shell(view).mask_zone == "America/Chicago"

      conn = conn_for(user) |> put_connect_params(%{"timezone" => "Not/AZone"})
      {:ok, view, _} = live(conn, "/inbox")
      assert shell(view).mask_zone == nil
    end
  end

  describe "the shell's toggle_mask_names on a page that masks nothing" do
    test "/inbox: off removes the key and on writes now + 12h; the view survives" do
      user = insert_user("inbox")
      set_until(user, DateTime.add(DateTime.utc_now(), 3600, :second))
      {view, _} = mount!(user, "/inbox")
      pid = view.pid

      render_hook(view, "toggle_mask_names", %{"masked" => "false"})
      assert stored_until(user) == nil
      assert shell(view).mask_names? == false
      assert view.pid == pid

      # Positive control: the same event with "true" writes the 12-hour key,
      # so the nil above is a write and not an event that did nothing.
      before = DateTime.utc_now()
      render_hook(view, "toggle_mask_names", %{"masked" => "true"})
      until = stored_until(user)
      assert %DateTime{} = until
      assert abs(DateTime.diff(until, DateTime.add(before, @twelve_hours, :second))) <= 5
      assert shell(view).mask_names? == true
      assert Accounts.mask_names_until(shell(view).current_user_record) == until
    end

    test "/settings: off removes the key and the switch reads aria-checked=false" do
      user = insert_user("settings")
      set_until(user, DateTime.add(DateTime.utc_now(), 3600, :second))
      {view, _} = mount!(user, "/settings")
      assert has_element?(view, "[data-role=settings-mask-names][aria-checked=true]")

      render_hook(view, "toggle_mask_names", %{"masked" => "false"})
      assert stored_until(user) == nil
      assert has_element?(view, "[data-role=settings-mask-names][aria-checked=false]")

      render_hook(view, "toggle_mask_names", %{"masked" => "true"})
      assert %DateTime{} = stored_until(user)
      assert has_element?(view, "[data-role=settings-mask-names][aria-checked=true]")
    end

    test "/inbox: one event is one write" do
      user = insert_user("inbox-once")
      {view, _} = mount!(user, "/inbox")

      {{_, updates}, writes} =
        count_writes(view, fn ->
          count_user_updates(user, fn ->
            render_hook(view, "toggle_mask_names", %{"masked" => "true"})
          end)
        end)

      assert writes == 1
      assert updates == 1
    end
  end

  describe "the masking pages own the event" do
    test "/chat: one event writes exactly once and unmasks the Chat list" do
      user = insert_user("chat-once")
      {:ok, _} = Accounts.put_mask_names(user.id, true)
      {view, before} = mount!(user, "/chat")

      # The list is masked before the event; the unmask below is its pair.
      for name <- @chat_orgs, do: refute_name_anywhere(before, name)

      {{html, updates}, writes} =
        count_writes(view, fn ->
          count_user_updates(user, fn ->
            render_hook(view, "toggle_mask_names", %{"masked" => "false"})
          end)
        end)

      assert writes == 1
      assert updates == 1
      assert stored_until(user) == nil
      for name <- @chat_orgs, do: assert_name_anywhere(html, name)
    end

    test "/tasks: one event writes exactly once and unmasks the rail" do
      projects = seed_projects()
      user = insert_user("tasks-once", true)
      {:ok, _} = Accounts.put_mask_names(user.id, true)
      {view, before} = mount!(user, "/tasks")

      before = without_scope_stylesheet(before)

      for name <- tasks_names(projects), do: refute_name_anywhere(before, name, @machine_attrs)

      {{html, updates}, writes} =
        count_writes(view, fn ->
          count_user_updates(user, fn ->
            render_hook(view, "toggle_mask_names", %{"masked" => "false"})
          end)
        end)

      assert writes == 1
      assert updates == 1
      assert stored_until(user) == nil
      for name <- tasks_names(projects), do: assert_name_anywhere(html, name)
    end

    test "/chat: turning it on refreshes @current_user_record to the new end time" do
      user = insert_user("chat-refresh")
      {view, _} = mount!(user, "/chat")
      assert Accounts.mask_names_until(shell(view).current_user_record) == nil

      before = DateTime.utc_now()
      render_hook(view, "toggle_mask_names", %{"masked" => "true"})

      until = Accounts.mask_names_until(shell(view).current_user_record)
      assert %DateTime{} = until
      assert abs(DateTime.diff(until, DateTime.add(before, @twelve_hours, :second))) <= 5
      assert shell(view).mask_names? == true
    end

    test "/tasks: turning it on refreshes @current_user_record to the new end time" do
      user = insert_user("tasks-refresh", true)
      {view, _} = mount!(user, "/tasks")
      assert Accounts.mask_names_until(shell(view).current_user_record) == nil

      before = DateTime.utc_now()
      render_hook(view, "toggle_mask_names", %{"masked" => "true"})

      until = Accounts.mask_names_until(shell(view).current_user_record)
      assert %DateTime{} = until
      assert abs(DateTime.diff(until, DateTime.add(before, @twelve_hours, :second))) <= 5
    end
  end

  describe "ShellLive.put_mask_names/2" do
    test "without a user record it returns the socket unchanged" do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user_record: nil}}
      assert ShellLive.put_mask_names(socket, true) == socket
    end
  end

  describe "guards" do
    @lib Path.expand("../../../lib", __DIR__)
    @app Path.expand("../../..", __DIR__)

    # Code lines only, as in mask_names_test.exs: comments and
    # @doc/@moduledoc heredocs may NAME the writer.
    defp code_lines(path) do
      {kept, _} =
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.reduce({[], false}, fn line, {kept, in_doc?} ->
          cond do
            in_doc? and String.trim(line) == ~s(""") -> {kept, false}
            in_doc? -> {kept, true}
            Regex.match?(~r/^\s*@(module)?doc\s+"""/, line) -> {kept, true}
            String.starts_with?(String.trim_leading(line), "#") -> {kept, false}
            true -> {[line | kept], false}
          end
        end)

      Enum.reverse(kept)
    end

    test "Accounts.put_mask_names( appears in lib/platform_web only in shell_live.ex" do
      files = Path.wildcard(Path.join(@lib, "platform_web/**/*.{ex,heex}"))
      assert length(files) > 100

      hits =
        for f <- files,
            line <- code_lines(f),
            String.contains?(line, "Accounts.put_mask_names("),
            do: Path.relative_to(f, @app)

      # Positive control: the scan finds the shell's own call.
      assert "lib/platform_web/live/shell_live.ex" in hits
      assert Enum.uniq(hits) == ["lib/platform_web/live/shell_live.ex"]
    end

    # Hook modules handle an event for the LiveView that attaches them.
    @hook_owner %{PlatformWeb.Tasks.MaskHooks => PlatformWeb.TasksLive}

    @handler_patterns [
      # def / defp handle_event("toggle_mask_names", ...)
      ~r/handle_event\(\s*"toggle_mask_names"/,
      # an anonymous attach_hook clause: "toggle_mask_names", params, socket ->
      ~r/^\s*"toggle_mask_names",\s*[a-z_]\w*,\s*[a-z_]\w*\s*->/
    ]

    test "the modules handling toggle_mask_names are mask_page_views plus the shell" do
      files = Path.wildcard(Path.join(@lib, "**/*.ex"))
      assert length(files) > 100

      handlers =
        for f <- files,
            lines = code_lines(f),
            Enum.any?(lines, fn l -> Enum.any?(@handler_patterns, &Regex.match?(&1, l)) end) do
          [_, mod] = Regex.run(~r/defmodule\s+([\w.]+)\s+do/, File.read!(f))
          mod = Module.concat([mod])
          Map.get(@hook_owner, mod, mod)
        end

      # Positive control: both clause forms are seen (the shell's anonymous
      # clause and ChatLive's def).
      assert PlatformWeb.ShellLive in handlers
      assert PlatformWeb.ChatLive in handlers

      assert Enum.sort(handlers) ==
               Enum.sort(ShellLive.mask_page_views() ++ [PlatformWeb.ShellLive])
    end
  end
end
