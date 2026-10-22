defmodule PlatformWeb.MaskNamesSharedTest do
  @moduledoc """
  Task 01a1557a-e538 stage 2: screen-share name masking is ONE per-user state
  with a 12-hour expiry (`Accounts.mask_names?/1`), read on mount by every
  masking LiveView (ChatLive, and TasksLive through `Tasks.MaskHooks`), and
  written by both `toggle_mask_names` handlers through
  `Accounts.put_mask_names/2`.

  Every refute of a real name runs over the WHOLE rendered document and has an
  unmasked control in the same test that asserts the name IS there, so a
  refute cannot pass against an empty render.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.MaskAssertions

  alias Platform.Accounts
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.{Repo, Tasks, Tenancy}
  alias Platform.Tenancy.OrgMembership

  # Seeded orgs whose three spellings differ (see `Platform.MaskAssertions`).
  @chat_orgs ["Vandelay-Ind", "Globex", "Initech"]
  @tenants ~w(initech vandelay_ind globex)
  # An `<option value>` carries a project UUID, not a name.
  @machine_attrs ~w(value)

  defp insert_user(tag, member?) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "mask-shared-#{tag}-#{n}@example.com",
        name: "Mask Shared #{tag} #{n}",
        oidc_sub: "oidc-mask-shared-#{tag}-#{n}"
      })

    # Tasks' project_sections are viewer-scoped, so a Tasks user is a member
    # everywhere (admin in Acme), exactly as the Tasks rail mask tests do.
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

  defp chat(user) do
    conn = conn_for(user)

    case live(conn, ~p"/chat") do
      {:error, {:live_redirect, %{to: to}}} -> live(conn, to)
      ok -> ok
    end
  end

  defp tasks(user), do: live(conn_for(user), ~p"/tasks")

  defp sidebar(html) do
    case Regex.run(~r/<aside[^>]*id="chat-sidebar".*?<\/aside>/s, html) do
      [match] -> match
      _ -> ""
    end
  end

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

  # The shell's `<style id="org-scope-colors">` block is a stylesheet whose
  # selectors are keyed on real org slugs (`[data-scope="initech"]{...}`).
  # Measured on the test rig, 2026-10-21: it is the ONLY place a real tenant name
  # survives in the masked /tasks document. It renders nothing on screen, so it
  # is outside a screen share's threat model, the same reason
  # `Platform.MaskAssertions` excludes `class`. Exactly that one element is
  # removed; everything else in the document is swept.
  defp without_scope_stylesheet(html) do
    Regex.replace(~r/<style id="org-scope-colors"[^>]*>.*?<\/style>/s, html, "")
  end

  defp set_until(user, %DateTime{} = until) do
    stored = Repo.get!(User, user.id)

    stored
    |> User.changeset(%{
      preferences:
        Map.put(stored.preferences || %{}, "mask_names_until", DateTime.to_iso8601(until))
    })
    |> Repo.update!()
  end

  setup do
    {:ok, _} = Chat.create_space(%{name: "General", slug: "general", kind: "channel"})
    :ok
  end

  test "(1) a stored mask masks a fresh /chat mount; another user is unaffected" do
    a = insert_user("chat-a", false)
    b = insert_user("chat-b", false)
    {:ok, _} = Accounts.put_mask_names(a.id, true)

    {:ok, _view, masked} = chat(a)
    {:ok, _view, unmasked} = chat(b)

    # Control: the same render for B, who stored nothing, carries every name.
    for name <- @chat_orgs, do: assert_name_anywhere(unmasked, name)
    refute sidebar(unmasked) =~ "channel-mask-strip"

    assert sidebar(masked) =~ "channel-mask-strip"
    assert masked =~ "Workspace A"
    for name <- @chat_orgs, do: refute_name_anywhere(masked, name)
  end

  test "(2) a stored mask masks a fresh /tasks mount: rail orgs and projects" do
    projects = seed_projects()
    a = insert_user("tasks-a", true)
    b = insert_user("tasks-b", true)
    {:ok, _} = Accounts.put_mask_names(a.id, true)

    {:ok, _view, unmasked} = tasks(b)
    {:ok, _view, masked} = tasks(a)

    for name <- tasks_names(projects), do: assert_name_anywhere(unmasked, name)
    # Anti-vacuity for the stripping below: the stylesheet is there to strip.
    assert masked =~ ~s(id="org-scope-colors")
    masked = without_scope_stylesheet(masked)
    for name <- tasks_names(projects), do: refute_name_anywhere(masked, name, @machine_attrs)
  end

  test "(3) on in Chat masks a fresh Tasks mount; off in Tasks unmasks a fresh Chat mount" do
    projects = seed_projects()
    a = insert_user("cross", true)

    {:ok, chat_view, before} = chat(a)
    refute sidebar(before) =~ "channel-mask-strip"

    chat_view
    |> element(~s(#chat-sidebar button[phx-click="toggle_mask_names"]))
    |> render_click(%{"masked" => "true"})

    {:ok, tasks_view, tasks_html} = tasks(a)
    tasks_html = without_scope_stylesheet(tasks_html)
    for name <- tasks_names(projects), do: refute_name_anywhere(tasks_html, name, @machine_attrs)

    tasks_view
    |> element("[data-role=rail-mask-toggle]")
    |> render_click(%{"masked" => "false"})

    refute Accounts.mask_names?(Repo.get!(User, a.id))

    {:ok, _view, after_off} = chat(a)
    refute sidebar(after_off) =~ "channel-mask-strip"
    assert sidebar(after_off) =~ ~s(aria-pressed="false")

    {:ok, _view, tasks_after} = tasks(a)
    for name <- tasks_names(projects), do: assert_name_anywhere(tasks_after, name)
  end

  test "(4) a stored instant one second in the past is unmasked" do
    a = insert_user("expired", false)
    set_until(a, DateTime.add(DateTime.utc_now(), -1, :second))

    {:ok, _view, html} = chat(a)
    refute sidebar(html) =~ "channel-mask-strip"
    for name <- @chat_orgs, do: assert_name_anywhere(html, name)

    # Control: one hour in the future, same user, same fixture, is masked.
    set_until(a, DateTime.add(DateTime.utc_now(), 3600, :second))
    {:ok, _view, masked} = chat(a)
    assert sidebar(masked) =~ "channel-mask-strip"
    for name <- @chat_orgs, do: refute_name_anywhere(masked, name)
  end

  test "(5) a reveal in one mount does not survive the next mount" do
    a = insert_user("reveal", false)
    {:ok, _} = Accounts.put_mask_names(a.id, true)

    {:ok, view, html} = chat(a)
    [_, section_id] = Regex.run(~r/data-section-id="([^"]+)"/, sidebar(html))

    revealed =
      view
      |> element(
        ~s(#chat-sidebar button[phx-click="reveal_section"][phx-value-section_id="#{section_id}"])
      )
      |> render_click()

    assert sidebar(revealed) =~ "1 showing"

    {:ok, _view, next} = chat(a)
    assert sidebar(next) =~ "channel-mask-strip"
    refute sidebar(next) =~ "1 showing"
    for name <- @chat_orgs, do: refute_name_anywhere(next, name)
  end
end
