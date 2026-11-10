defmodule PlatformWeb.GettingStartedLiveTest do
  @moduledoc """
  `/setup/getting-started`, the holding page while the starter key provisions
  Burrow in a task (`Platform.Agents.Burrow.Starter.start_provisioning/1`).

  Mutants these name:

    * subscribe after the database read → "a result that arrived before the
      mount" can only pass by luck; the test provisions first;
    * drop the `{:starter, _failed}` clause → "a failed provisioning goes to
      the picker" hangs on the holding page;
    * drop the give-up timer → "gives up to the picker" goes red;
    * drop the root-admin check → "a member is refused" goes red.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Agents.Burrow.Starter
  alias Platform.VaultFixtures

  @starter "sk-ant-api03-" <> String.duplicate("s", 40) <> "GETTINGSTARTtail"

  setup %{conn: conn} do
    previous = Application.get_env(:platform, :starter_anthropic_api_key)
    previous_token = Application.get_env(:platform, :agent_host_token)
    Application.put_env(:platform, :starter_anthropic_api_key, @starter)
    Application.put_env(:platform, :agent_host_token, "test-host-token")
    Application.put_env(:platform, PlatformWeb.GettingStartedLive, wait_ms: 150)

    on_exit(fn ->
      Application.put_env(:platform, :starter_anthropic_api_key, previous)
      Application.put_env(:platform, :agent_host_token, previous_token)
      Application.delete_env(:platform, PlatformWeb.GettingStartedLive)
    end)

    admin = VaultFixtures.admin!()
    %{conn: Plug.Test.init_test_session(conn, %{"current_user_id" => admin.id}), admin: admin}
  end

  test "holds, then navigates to the conversation when the task answers", %{conn: conn} do
    Application.put_env(:platform, PlatformWeb.GettingStartedLive, wait_ms: 60_000)
    {:ok, view, html} = live(conn, ~p"/setup/getting-started")
    assert html =~ "is getting ready"
    assert has_element?(view, "#getting-started-wait")

    send(view.pid, {:starter, {:ok, %{slug: "getting-started-abc"}}})
    assert_redirect(view, "/chat/getting-started-abc")
  end

  test "a result that arrived before the mount is not missed", %{conn: conn, admin: admin} do
    {:ok, space} = Starter.provision(admin)
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/setup/getting-started")
    assert to == "/chat/" <> space.slug
  end

  test "a failed provisioning goes to the picker", %{conn: conn} do
    Application.put_env(:platform, PlatformWeb.GettingStartedLive, wait_ms: 60_000)
    {:ok, view, _html} = live(conn, ~p"/setup/getting-started")
    send(view.pid, {:starter, {:error, :boom}})
    assert_redirect(view, "/setup/connect-ai")
  end

  test "gives up to the picker when nothing answers", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup/getting-started")
    assert_redirect(view, "/setup/connect-ai", 2_000)
  end

  test "without a starter key there is nothing to wait for", %{conn: conn} do
    Application.put_env(:platform, :starter_anthropic_api_key, nil)

    assert {:error, {:live_redirect, %{to: "/setup/connect-ai"}}} =
             live(conn, ~p"/setup/getting-started")
  end

  test "a member is refused", %{conn: conn} do
    member = VaultFixtures.non_admin!()
    conn = Plug.Test.init_test_session(conn, %{"current_user_id" => member.id})

    assert {:error, {:redirect, %{to: "/access-denied?module=admin"}}} =
             live(conn, ~p"/setup/getting-started")
  end
end
