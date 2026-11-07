defmodule PlatformWeb.AuthControllerWelcomeTest do
  @moduledoc """
  Task 01a1b6de stage 2: a new member's arrival (a full internal sign-in)
  triggers Burrow's welcome once, and the sign-in itself is the login record
  the setup checklist reads.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Agents.NativeAgents
  alias Platform.Chat.Message
  alias Platform.Onboarding.PersonSetup
  alias Platform.Repo

  setup do
    on_exit(fn -> Application.delete_env(:platform, :oidc_mock_response) end)

    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "acw-owner-#{n}@example.com",
        name: "Owner #{n}",
        oidc_sub: "oidc-acw-owner-#{n}"
      })

    {:ok, agent, _runtime} = NativeAgents.create(owner.id, %{name: "Burrow", harness: "codex"})
    %{agent: agent}
  end

  defp welcomes(user_id) do
    Repo.all(
      from(m in Message,
        where:
          fragment("?->>'source' = 'member_welcome'", m.metadata) and
            fragment("?->>'welcome_user_id' = ?", m.metadata, ^user_id)
      )
    )
  end

  defp dev_login(conn, slug) do
    conn
    |> init_test_session(%{})
    |> PlatformWeb.AuthController.dev_login(%{"as" => slug})
  end

  test "a first dev sign-in posts the welcome; a second posts nothing more", %{conn: conn} do
    slug = "welcome#{System.unique_integer([:positive])}"

    first = dev_login(conn, slug)
    assert redirected_to(first, 302) == ~p"/chat"
    user_id = get_session(first, :current_user_id)
    assert [_one] = welcomes(user_id)

    second = dev_login(build_conn(), slug)
    assert get_session(second, :current_user_id) == user_id
    assert [_still_one] = welcomes(user_id)
  end

  test "the sign-in is the checklist's login record", %{conn: conn} do
    slug = "record#{System.unique_integer([:positive])}"
    user_id = conn |> dev_login(slug) |> get_session(:current_user_id)

    status = PersonSetup.status(user_id, stuck_after_seconds: nil)
    assert %DateTime{} = status.first_sign_in_at
    assert Enum.find(status.steps, &(&1.step == :signed_in)).state == :done
    assert Enum.find(status.steps, &(&1.step == :who_to_ask)).state == :done
  end

  test "an OIDC callback sign-in posts the welcome once", %{conn: conn} do
    n = System.unique_integer([:positive])

    claims = %{
      "sub" => "oidc-acw-#{n}",
      "email" => "acw-#{n}@example.com",
      "name" => "Callback Person"
    }

    Application.put_env(
      :platform,
      :oidc_mock_response,
      {:ok, %{user: claims, userinfo: claims, id_token: claims, token: %{"id_token" => "t"}}}
    )

    login = fn conn ->
      conn
      |> init_test_session(oidc_session_params: %{state: "expected-state", nonce: "n"})
      |> get(~p"/auth/oidc/callback?code=test-code&state=expected-state")
    end

    conn = login.(conn)
    user_id = get_session(conn, :current_user_id)
    assert user_id
    assert [_one] = welcomes(user_id)

    login.(build_conn())
    assert [_still_one] = welcomes(user_id)
  end
end
