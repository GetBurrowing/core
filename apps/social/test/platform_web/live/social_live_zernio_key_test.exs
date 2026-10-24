defmodule PlatformWeb.SocialLiveZernioKeyTest do
  @moduledoc """
  The install's Zernio API key row in Social Settings (task 01a14722,
  stage 3): a live human sets and replaces it through
  `Platform.Social.Secrets.put_zernio_api_key/2`; the value never reaches
  the HTML (not even its fingerprint); an agent or archived user's forged
  save writes nothing; and under the Zernio publisher, Connections hides
  Connect until the key is set. `async: false`: the publisher config and
  the install-level Vault row are global.

  An agent session has no profile and so no Settings pane, which makes the
  agent render-refute structural; the HANDLER's re-read of the user is what
  the forged-save tests pin.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.SocialFixtures
  import Platform.SocialApprovalFixtures

  alias Platform.Repo
  alias Platform.Social.Publisher.Fake
  alias Platform.Vault

  @slug "social:zernio:api_key"
  @scope {:integration, nil}
  @row "[data-role='social-zernio-key']"

  setup do
    Fake.reset()
    approval_fixture()
  end

  defp open(conn, user, tab \\ "settings") do
    conn = Plug.Test.init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/m/social")
    child = find_live_child(view, "ext-page-social")
    child |> element("[data-role='social-tab-button'][data-tab='#{tab}']") |> render_click()
    child
  end

  defp save(child, value) do
    child
    |> form("[data-role='social-zernio-key-form']", zernio_key: %{api_key: value})
    |> render_submit()
  end

  defp stored, do: Vault.get_unique(@slug, scope: @scope, accessor: @scope)
  defp rows, do: [scope: @scope] |> Vault.list() |> Enum.filter(&(&1.slug == @slug))

  defp select_zernio do
    previous = Application.get_env(:social, :publisher)
    Application.put_env(:social, :publisher, Platform.Social.Publisher.Zernio)
    on_exit(fn -> Application.put_env(:social, :publisher, previous) end)
  end

  test "a human sees Not set, saves a key, and the Vault holds it; the row then shows Set and Last changed by",
       %{conn: conn} = ctx do
    child = open(conn, ctx.n)

    assert has_element?(child, @row <> "[data-state='not_set']")
    assert has_element?(child, "[data-role='social-zernio-status']", "Not set")

    assert has_element?(
             child,
             "[data-role='social-zernio-scope']",
             "One key for the whole org. Used by every profile."
           )

    assert has_element?(child, "[data-role='social-zernio-helper']", "Find it in Zernio")

    assert has_element?(
             child,
             "input[data-role='social-zernio-key-input'][type='password'][autocomplete='off'][placeholder='paste key']"
           )

    # The placeholder paints text-subtle (direction canvas rule 1; task
    # 01a15907 stage 3, was the 70% slot), not daisy's /50 default, which
    # measured 3.95:1 on the row's base-100 in light theme (stage 5).
    assert has_element?(
             child,
             "input[data-role='social-zernio-key-input'][class~='placeholder:text-subtle']"
           )

    refute has_element?(child, "[data-role='social-zernio-key-form'][phx-change]")
    refute has_element?(child, "[data-role='social-zernio-replace']")

    key = "zk-test-#{unique()}-not-real"
    save(child, key)

    assert {:ok, ^key} = stored()
    assert has_element?(child, @row <> "[data-state='set']")
    assert has_element?(child, "[data-role='social-zernio-status']", "Set")

    assert has_element?(
             child,
             "[data-role='social-zernio-changed']",
             "Last changed by Nina Viewer"
           )

    assert has_element?(child, "[data-role='social-zernio-replace']", "Replace")
    refute has_element?(child, "[data-role='social-zernio-key-input']")
  end

  test "the rendered page contains neither the key nor its fingerprint, before or after Replace",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    key = "zk-secret-#{unique()}-not-real"
    save(child, key)

    html = render(child)
    refute html =~ key
    refute html =~ Vault.fingerprint(key)
    # Nor is it kept in the LiveView's state (assigns, form params).
    refute inspect(:sys.get_state(child.pid), limit: :infinity, printable_limit: :infinity) =~
             key

    child |> element("[data-role='social-zernio-replace']") |> render_click()
    html = render(child)
    refute html =~ key
    refute html =~ Vault.fingerprint(key)
    assert has_element?(child, "input[data-role='social-zernio-key-input'][value='']")
  end

  test "Replace leaves exactly one row, holding the new value; Cancel returns to Set",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    save(child, "zk-first-not-real")

    child |> element("[data-role='social-zernio-replace']") |> render_click()

    assert has_element?(
             child,
             "input[data-role='social-zernio-key-input'][placeholder='paste new key']"
           )

    child |> element("[data-role='social-zernio-cancel']") |> render_click()
    refute has_element?(child, "[data-role='social-zernio-key-input']")
    assert {:ok, "zk-first-not-real"} = stored()

    child |> element("[data-role='social-zernio-replace']") |> render_click()
    save(child, "zk-second-not-real")

    assert [_one] = rows()
    assert {:ok, "zk-second-not-real"} = stored()
    assert has_element?(child, "[data-role='social-zernio-changed']", "Last changed by Hana One")
  end

  test "a blank submit shows the failed-save state and writes nothing; Try again reopens an empty input",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h1)
    save(child, "   ")

    assert rows() == []

    assert has_element?(
             child,
             "[data-role='social-zernio-error']",
             "Couldn't save the key. Nothing was changed."
           )

    refute has_element?(child, "[data-role='social-zernio-key-input']")

    child |> element("[data-role='social-zernio-retry']") |> render_click()
    refute has_element?(child, "[data-role='social-zernio-error']")
    assert has_element?(child, "input[data-role='social-zernio-key-input'][value='']")
  end

  test "an agent session has no row, and its forged save writes nothing (positive control: a human's identical payload writes)",
       %{conn: conn} = ctx do
    {:ok, g_view, _html} =
      live_isolated(conn, PlatformWeb.SocialLive, session: %{"user_id" => ctx.g.id})

    refute has_element?(g_view, @row)

    payload = %{"zernio_key" => %{"api_key" => "zk-forged-not-real"}}
    render_hook(g_view, "save_zernio_key", payload)

    assert Process.alive?(g_view.pid)
    assert rows() == []
    refute has_element?(g_view, @row)

    h_child = open(build_conn(), ctx.n)
    render_hook(h_child, "save_zernio_key", payload)
    assert {:ok, "zk-forged-not-real"} = stored()
  end

  test "a forged save from a user archived after mount is refused (positive control: a live human writes)",
       %{conn: conn} = ctx do
    child = open(conn, ctx.h2)
    assert has_element?(child, @row)

    ctx.h2
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
    |> Repo.update!()

    payload = %{"zernio_key" => %{"api_key" => "zk-archived-not-real"}}
    render_hook(child, "save_zernio_key", payload)

    assert Process.alive?(child.pid)
    assert rows() == []
    refute has_element?(child, @row)

    h_child = open(build_conn(), ctx.h1)
    render_hook(h_child, "save_zernio_key", payload)
    assert {:ok, "zk-archived-not-real"} = stored()
  end

  describe "Connections under the Zernio publisher" do
    test "with no key: the notice shows and Connect/Reconnect are hidden; after a save they come back",
         %{conn: conn} = ctx do
      select_zernio()
      child = open(conn, ctx.h1, "connections")

      assert has_element?(
               child,
               "[data-role='social-zernio-required']",
               "Add the Zernio API key in Settings before connecting accounts."
             )

      refute has_element?(child, "[data-role='social-account-connect']")

      assert has_element?(
               child,
               "[data-role='social-account-state'][data-state='none']",
               "Not connected"
             )

      child |> element("[data-role='social-zernio-go-settings']") |> render_click()
      assert has_element?(child, "[data-role='social-tab-body'][data-tab='settings']")

      save(child, "zk-connect-not-real")

      refute has_element?(child, "[data-role='social-zernio-required']")
      assert has_element?(child, "[data-role='social-account-connect']", "Connect")
    end

    test "under the Fake publisher there is no notice and Connect shows", %{conn: conn} = ctx do
      child = open(conn, ctx.h1, "connections")

      refute has_element?(child, "[data-role='social-zernio-required']")
      assert has_element?(child, "[data-role='social-account-connect']")
    end
  end
end
