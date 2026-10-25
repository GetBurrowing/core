defmodule PlatformWeb.CommandPaletteLiveTest do
  @moduledoc """
  `PlatformWeb.CommandPaletteLive` (Burrow redesign 23, stage 2): the shell's
  one command palette renders closed on every shell page, loads its Sources
  only when opened, filters as you type, navigates by index, and shows a
  guest or a masked viewer only what their own list shows.

  Every refute of a name has a positive control in the same test that shows
  the same name where it should be.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.TenancyFixtures

  alias Platform.Access.Scope
  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.CommandPalette.Sources
  alias PlatformWeb.Components.Sidebar

  defp n, do: System.unique_integer([:positive])

  defp user!(opts \\ []) do
    k = n()

    user =
      Repo.insert!(%User{
        email: "cmdk-live-#{k}@example.com",
        name: "Cmdk Live #{k}",
        oidc_sub: "cmdk-live-#{k}"
      })

    if Keyword.get(opts, :all_orgs, false) do
      for org <- Tenancy.list_orgs() do
        role = if org.slug == "acme", do: "admin", else: "member"

        %OrgMembership{}
        |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: role})
        |> Repo.insert!()
      end
    else
      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: user.id, org_id: acme_org_id(), role: "admin"})
      |> Repo.insert!()
    end

    user
  end

  defp guest!(org_id) do
    k = n()

    user =
      Repo.insert!(%User{
        email: "cmdk-live-g-#{k}@example.com",
        name: "Guest #{k}",
        oidc_sub: "cmdk-live-g-#{k}"
      })

    {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: org_id})
    user
  end

  defp channel!(name, opts \\ []) do
    attrs = Map.merge(%{name: name, slug: "cmdk-live-#{n()}", kind: "channel"}, Map.new(opts))
    {:ok, ch} = Chat.create_space(attrs)
    ch
  end

  defp join!(space, user) do
    {:ok, _} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    space
  end

  defp mask!(user) do
    stored = Repo.get!(User, user.id)
    until = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

    stored
    |> User.changeset(%{
      preferences: Map.put(stored.preferences || %{}, "mask_names_until", until)
    })
    |> Repo.update!()
  end

  defp mount!(user, path) do
    conn = init_test_session(build_conn(), current_user_id: user.id)

    case live(conn, path) do
      {:ok, view, html} -> {view, html}
      {:error, {:live_redirect, %{to: to}}} -> mount!(user, to)
      {:error, {:redirect, %{to: to}}} -> mount!(user, to)
    end
  end

  defp palette(view), do: with_target(view, "#command-palette")
  defp open!(view), do: view |> palette() |> render_hook("palette_open", %{})

  defp query!(view, q),
    do: view |> form("#command-palette-form", palette: %{q: q}) |> render_change()

  defp q(html, selector), do: html |> LazyHTML.from_document() |> LazyHTML.query(selector)

  defp rows(html) do
    html
    |> q("#command-palette-results [role=option]")
    |> Enum.map(fn row ->
      # The icon span (which may hold an <.icon> span) first, the label last.
      spans = Enum.map(LazyHTML.query(row, "span"), &String.trim(LazyHTML.text(&1)))
      {icon, label} = {hd(spans), List.last(spans)}
      kind = row |> LazyHTML.query("small") |> LazyHTML.text()
      Enum.join(Enum.reject([icon, label, kind], &(&1 == "")), " ")
    end)
  end

  defp palette_text(html), do: html |> q("#command-palette") |> LazyHTML.text()

  defp attr(html, selector, name),
    do: html |> q(selector) |> LazyHTML.attribute(name) |> List.first()

  describe "closed on every shell page" do
    test "/chat and /tasks render #command-palette with data-open=false and no box" do
      user = user!()

      for path <- ["/chat", "/tasks"] do
        {view, _} = mount!(user, path)
        html = render(view)

        assert attr(html, "#command-palette", "data-open") == "false", path
        assert attr(html, "#command-palette", "aria-modal") == "true", path
        assert attr(html, "#command-palette", "role") == "dialog", path
        assert attr(html, "#command-palette", "class") =~ "hidden"
        assert has_element?(view, "#command-palette[aria-label='Command palette']")
        refute has_element?(view, "#command-palette-box")
        refute has_element?(view, "#command-palette-input")
      end
    end

    test "Sources is not read until palette_open" do
      user = user!()
      test_pid = self()

      # A separate tracer: it forwards every Sources.load/1 call, from the
      # dead render (this process) or the LiveView (a new process), here.
      tracer =
        spawn_link(fn ->
          loop = fn loop ->
            receive do
              {:trace, pid, :call, {Sources, :load, _}} -> send(test_pid, {:sources_load, pid})
              _ -> :ok
            end

            loop.(loop)
          end

          loop.(loop)
        end)

      :erlang.trace_pattern({Sources, :load, 1}, true, [:global])
      :erlang.trace(self(), true, [:call, {:tracer, tracer}])
      :erlang.trace(:new_processes, true, [:call, {:tracer, tracer}])
      on_exit(fn -> :erlang.trace_pattern({Sources, :load, 1}, false, [:global]) end)

      {view, _} = mount!(user, "/chat")
      :erlang.trace(:new_processes, false, [:call])
      :erlang.trace(self(), false, [:call])
      _ = render(view)

      refute_receive {:sources_load, _}, 200

      open!(view)
      view_pid = view.pid
      assert_receive {:sources_load, ^view_pid}, 1_000
      :erlang.trace(view_pid, false, [:call])
    end
  end

  describe "open" do
    setup do
      user = user!()
      beta = channel!("beta", slug: "beta") |> join!(user)
      team_beta = channel!("team-beta") |> join!(user)
      %{user: user, beta: beta, team_beta: team_beta}
    end

    test "palette_open shows the input and 14 rows, the sidebar's first module first", ctx do
      {view, _} = mount!(ctx.user, "/chat")
      html = open!(view)

      assert attr(html, "#command-palette", "data-open") == "true"
      assert attr(html, "#command-palette", "class") =~ "lg:flex"
      assert has_element?(view, "#command-palette-input[name='palette[q]']")

      assert attr(html, "#command-palette-input", "placeholder") ==
               "Jump to a module, space, person, file…"

      assert length(rows(html)) == 14

      {[first | _], _} = Sidebar.rows(Scope.for_user(Accounts.get_user(ctx.user.id)), false)
      assert hd(rows(html)) =~ first.label
      assert hd(rows(html)) =~ "module"
      assert attr(html, "#command-palette-row-0", "aria-selected") == "true"
      assert attr(html, "#command-palette-row-1", "aria-selected") == "false"
      assert attr(html, "#command-palette-row-0", "href") == first.path
    end

    test "palette_query \"bet\" shows beta first", ctx do
      {view, _} = mount!(ctx.user, "/chat")
      open!(view)
      html = query!(view, "bet")

      assert [first, second | _] = rows(html)
      assert first == "# beta space"
      assert second == "# team-beta space"
      assert attr(html, "#command-palette-row-0", "href") == "/chat/beta"
    end

    test "palette_go navigates to /chat/beta", ctx do
      {view, _} = mount!(ctx.user, "/tasks")
      open!(view)
      query!(view, "bet")

      assert {:error, {:live_redirect, %{to: "/chat/beta"}}} =
               view |> form("#command-palette-form") |> render_submit()
    end

    test "palette_go follows the index, and falls back to the first result", ctx do
      {view, _} = mount!(ctx.user, "/chat")
      open!(view)
      to = "/chat/#{ctx.team_beta.slug}"

      assert {:error, {:live_redirect, %{to: ^to}}} =
               view |> palette() |> render_hook("palette_go", %{"q" => "bet", "index" => 1})

      {view, _} = mount!(ctx.user, "/chat")
      open!(view)

      assert {:error, {:live_redirect, %{to: "/chat/beta"}}} =
               view |> palette() |> render_hook("palette_go", %{"q" => "bet", "index" => "99"})
    end

    test "palette_go with no result does nothing", ctx do
      {view, _} = mount!(ctx.user, "/chat")
      open!(view)

      html = view |> palette() |> render_hook("palette_go", %{"q" => "zzqx-none", "index" => 0})
      assert attr(html, "#command-palette", "data-open") == "true"
    end

    test "a query with no result shows \"No match.\"", ctx do
      {view, _} = mount!(ctx.user, "/chat")
      open!(view)
      html = query!(view, "zzqx-none")

      assert rows(html) == []
      assert html |> q("#command-palette-results div") |> LazyHTML.text() == "No match."
    end

    test "palette_close sets data-open=false; palette_toggle flips it", ctx do
      {view, _} = mount!(ctx.user, "/chat")
      open!(view)
      html = view |> palette() |> render_hook("palette_close", %{})
      assert attr(html, "#command-palette", "data-open") == "false"
      refute has_element?(view, "#command-palette-box")

      html = view |> palette() |> render_hook("palette_toggle", %{})
      assert attr(html, "#command-palette", "data-open") == "true"
      html = view |> palette() |> render_hook("palette_toggle", %{})
      assert attr(html, "#command-palette", "data-open") == "false"
    end

    test "a canvas row navigates across live_sessions to /canvases/:id", ctx do
      {:ok, author} =
        Chat.add_participant(ctx.beta.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Author",
          joined_at: DateTime.utc_now()
        })

      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => ctx.beta.id,
          "created_by" => author.id,
          "title" => "Cmdk hop canvas"
        })

      {view, _} = mount!(ctx.user, "/chat")
      open!(view)
      to = "/canvases/#{canvas.id}"

      assert {:error, {:live_redirect, %{to: ^to}}} =
               view |> palette() |> render_hook("palette_go", %{"q" => "hop canvas"})
    end

    test "an unknown message to the LiveView on /tasks with the palette open does not crash",
         ctx do
      {view, _} = mount!(ctx.user, "/tasks")
      open!(view)
      ref = Process.monitor(view.pid)

      send(view.pid, {:cmdk_unknown_message, make_ref()})
      send(view.pid, :cmdk_unknown_atom)

      html = render(view)
      refute_received {:DOWN, ^ref, _, _, _}
      assert attr(html, "#command-palette", "data-open") == "true"
      assert length(rows(html)) == 14
    end
  end

  test "a guest viewer's open palette has no internal-only channel" do
    org_id = tenant_org_id("cmdk-live-guest-#{n()}")
    guest = guest!(org_id)
    allowed = channel!("Cmdk Live Allowed", org_id: org_id) |> join!(guest)
    internal = channel!("Cmdk Live Internal Only")

    {view, _} = mount!(guest, "/chat/#{allowed.slug}")
    assert has_element?(view, "#command-palette[data-open='false']")
    html = open!(view)
    text = palette_text(html)

    assert text =~ allowed.name
    refute text =~ internal.name

    # Positive control: an internal admin's palette carries it.
    {view, _} = mount!(user!(), "/chat")
    open!(view)
    html = query!(view, "Cmdk Live")
    assert palette_text(html) =~ internal.name
  end

  test "a masked viewer's palette never renders the real sub-org channel name" do
    globex = Tenancy.get_org_by_slug("globex") || raise "seeded globex org missing"
    channel = channel!("Globex", org_id: globex.id)

    viewer = user!(all_orgs: true)

    # Positive control first: unmasked, the real name is there.
    {view, _} = mount!(viewer, "/chat")
    open!(view)
    assert palette_text(query!(view, "globex")) =~ "Globex"

    mask!(viewer)
    {view, _} = mount!(viewer, "/chat")
    open!(view)

    for query <- ["", "globex", "workspace", "space"] do
      text = palette_text(query!(view, query))
      refute text =~ "Globex", "query #{inspect(query)} rendered the real name"
    end

    html = query!(view, "workspace-")
    assert palette_text(html) =~ "workspace-"

    # The masked row links by id, as the list pane does; the slug never renders.
    hrefs = html |> q("#command-palette-results [role=option]") |> LazyHTML.attribute("href")
    assert "/chat/#{channel.id}" in hrefs
    refute Enum.any?(hrefs, &(&1 =~ channel.slug)), "a row href carried the real slug"
  end

  describe "keyboard hook (stage 4)" do
    test "/tasks: palette_toggle twice leaves data-open=false; the root carries the hook" do
      user = user!()
      {view, html} = mount!(user, "/tasks")

      assert attr(html, "#command-palette", "phx-hook") == "CommandPalette"

      html = view |> palette() |> render_hook("palette_toggle", %{})
      assert attr(html, "#command-palette", "data-open") == "true"
      assert attr(html, "#command-palette-results", "data-query") == ""
      assert attr(html, "#command-palette-row-0", "class") =~ "aria-selected:bg-base-300"

      html = view |> palette() |> render_hook("palette_toggle", %{})
      assert attr(html, "#command-palette", "data-open") == "false"
      refute has_element?(view, "#command-palette-box")
    end

    test "the listbox echoes the rendered query for the hook's selection reset" do
      user = user!()
      {view, _} = mount!(user, "/tasks")
      open!(view)

      assert attr(query!(view, "tas"), "#command-palette-results", "data-query") == "tas"
    end
  end
end
