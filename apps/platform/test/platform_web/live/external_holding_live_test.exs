defmodule PlatformWeb.ExternalHoldingLiveTest do
  @moduledoc """
  Coverage for the zero-access holding landing (rbac-external-users M3
  stage 2, task 019f8837).

    * a session carrying the `:external_admission` holding key renders the
      calm holding card and NO shell chrome / icon-rail (zero-access, no
      discovery leak);
    * an ordinary internal session with NO holding key is bounced to `/chat`
      (never park an internal user here — the regression guard);
    * a mounted holding tab that receives the `:recovered` broadcast
      push-navigates to `/chat` — the seamless live-recovery unit.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.ExternalAdmission
  alias Platform.Accounts.User
  alias Platform.Repo

  defp create_user!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          email: "holding-#{n}@example.com",
          name: "Holding #{n}",
          oidc_sub: "oidc-holding-#{n}"
        },
        overrides
      )

    %User{} |> User.changeset(attrs) |> Repo.insert!()
  end

  defp holding_conn(conn, user) do
    Plug.Test.init_test_session(conn, %{
      "current_user_id" => user.id,
      "external_admission" => %{state: :holding, reason: :awaiting_grant, user_id: user.id}
    })
  end

  defp internal_conn(conn, user) do
    Plug.Test.init_test_session(conn, %{"current_user_id" => user.id})
  end

  describe "holding session" do
    test "renders the holding card with only brand chip + logout, no shell chrome", %{conn: conn} do
      user = create_user!()

      {:ok, view, html} = conn |> holding_conn(user) |> live("/welcome")

      # The calm card + its zero-access affordances are present.
      assert has_element?(view, "[data-role=holding-card]")
      assert has_element?(view, "[data-role=brand-chip]")
      assert has_element?(view, "[data-role=holding-logout]")
      assert html =~ "your workspace is being set up"

      # No shell / icon rail / bottom nav — the discovery leak the separate
      # live_session + chrome-less layout exist to prevent.
      refute has_element?(view, "#shell-sidebar")
      refute has_element?(view, "nav")
    end
  end

  describe "non-holding session" do
    test "an internal user with no holding key is redirected to /chat", %{conn: conn} do
      user = create_user!()

      assert {:error, {:live_redirect, %{to: "/chat"}}} =
               conn |> internal_conn(user) |> live("/welcome")
    end
  end

  describe "seamless recovery" do
    test "a :recovered broadcast push-navigates the holding tab to /chat", %{conn: conn} do
      user = create_user!()

      {:ok, view, _html} = conn |> holding_conn(user) |> live("/welcome")

      result = %ExternalAdmission.Result{
        user: user,
        state: :full,
        reason: nil,
        external?: true
      }

      send(view.pid, {:external_admission, :recovered, user.id, result})

      assert_redirect(view, "/chat")
    end
  end
end
