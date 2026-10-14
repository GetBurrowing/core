defmodule PlatformWeb.ReconnectEscalationTest do
  @moduledoc """
  The reconnect escalation thresholds (task 01a12b10 stage 1):
  `PlatformWeb.ReconnectEscalation.config/0` applies the defaults and clamps,
  and the root layout renders them into `<meta name="reconnect-escalation">`
  on every page load, re-reading the application env each time.

  async: false because every test put_envs `:platform, :reconnect_escalation`.
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts.User
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.ReconnectEscalation

  setup do
    previous = Application.fetch_env(:platform, :reconnect_escalation)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :reconnect_escalation, value)
        :error -> Application.delete_env(:platform, :reconnect_escalation)
      end
    end)

    :ok
  end

  defp put(env), do: Application.put_env(:platform, :reconnect_escalation, env)

  describe "config/0" do
    test "defaults to 11 attempts and 10 seconds when unset" do
      Application.delete_env(:platform, :reconnect_escalation)
      assert ReconnectEscalation.config() == %{attempts: 11, seconds: 10}
      assert ReconnectEscalation.defaults() == %{attempts: 11, seconds: 10}
    end

    test "returns configured values" do
      put(attempts: 3, seconds: 25)
      assert ReconnectEscalation.config() == %{attempts: 3, seconds: 25}
    end

    test "falls back per key on garbage, zero and negatives" do
      for bad <- [nil, 0, -1, "5", 2.5, :ten] do
        put(attempts: bad, seconds: bad)
        assert ReconnectEscalation.config() == %{attempts: 11, seconds: 10}, inspect(bad)
      end

      put(attempts: 4, seconds: "x")
      assert ReconnectEscalation.config() == %{attempts: 4, seconds: 10}

      put(:not_a_keyword_list)
      assert ReconnectEscalation.config() == %{attempts: 11, seconds: 10}
    end

    test "clamps attempts to 1..100 and seconds to 1..300" do
      put(attempts: 1000, seconds: 100_000)
      assert ReconnectEscalation.config() == %{attempts: 100, seconds: 300}

      put(attempts: 1, seconds: 1)
      assert ReconnectEscalation.config() == %{attempts: 1, seconds: 1}
    end

    test "the JS engine carries the same defaults and clamps" do
      # Two copies of one rule (architecture note on the plan): the JS
      # fallback applies when the meta tag is missing. Pin them together.
      js =
        File.read!(Path.expand("../../assets/js/lib/reconnect_escalation.js", __DIR__))

      for {name, value} <- [
            {"DEFAULT_ATTEMPTS", 11},
            {"DEFAULT_SECONDS", 10},
            {"MAX_ATTEMPTS", 100},
            {"MAX_SECONDS", 300}
          ] do
        assert js =~ "export const #{name} = #{value}\n", "#{name} drifted from #{value}"
      end

      put(attempts: 100_000, seconds: 100_000)
      assert ReconnectEscalation.config() == %{attempts: 100, seconds: 300}
    end
  end

  describe "root layout meta" do
    defp user! do
      n = System.unique_integer([:positive])

      user =
        %User{}
        |> User.changeset(%{
          email: "reconnect-escalation-#{n}@example.com",
          name: "Reconnect Escalation #{n}",
          oidc_sub: "oidc-reconnect-escalation-#{n}"
        })
        |> Repo.insert!()

      %OrgMembership{}
      |> OrgMembership.changeset(%{
        user_id: user.id,
        org_id: Tenancy.get_org_by_slug!("acme").id,
        role: "admin"
      })
      |> Repo.insert!()

      user
    end

    defp meta(user) do
      html =
        build_conn()
        |> Plug.Test.init_test_session(%{"current_user_id" => user.id})
        |> get("/tasks")
        |> html_response(200)

      [tag] = Regex.scan(~r{<meta[^>]*name="reconnect-escalation"[^>]*>}, html) |> Enum.map(&hd/1)
      [_, attempts] = Regex.run(~r{data-attempts="([^"]*)"}, tag)
      [_, seconds] = Regex.run(~r{data-seconds="([^"]*)"}, tag)
      {attempts, seconds}
    end

    test "renders the configured values and re-reads them on the next request" do
      user = user!()

      put(attempts: 7, seconds: 42)
      assert meta(user) == {"7", "42"}

      put(attempts: 100, seconds: 3)
      assert meta(user) == {"100", "3"}

      Application.delete_env(:platform, :reconnect_escalation)
      assert meta(user) == {"11", "10"}
    end
  end
end
