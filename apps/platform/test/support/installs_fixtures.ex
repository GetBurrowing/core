defmodule Platform.InstallsFixtures do
  @moduledoc """
  Fixtures for `Platform.Installs` (task 01a10315 stage 2).

  `use_fake_backend/1` points the whole install pipeline at dev stub mode's
  fakes for one test: DigitalOcean is `PlatformWeb.Dev.FakeDigitalOcean`
  behind the `Req.Test` stub (shared mode, so a runner in another process
  reaches it), and render, probes and bootstrap are `Platform.Installs.Fake`.
  Every credential here is an obviously fake test string.
  """

  import ExUnit.Callbacks

  alias Platform.Installs
  alias Platform.Installs.DigitalOcean
  alias Platform.Installs.Fake
  alias Platform.VaultFixtures

  @doc """
  Set up the fake backend. `wrap` (optional) receives the conn and a
  continuation that runs the fake plug, so a test can intercept one call.
  """
  def use_fake_backend(overrides \\ [], wrap \\ nil) do
    start_supervised!(Fake)
    Req.Test.set_req_test_to_shared(%{})
    on_exit(fn -> Req.Test.set_req_test_to_private(%{}) end)

    stub =
      case wrap do
        nil -> fn conn -> PlatformWeb.Dev.FakeDigitalOcean.call(conn, []) end
        wrap -> fn conn -> wrap.(conn, &PlatformWeb.Dev.FakeDigitalOcean.call(&1, [])) end
      end

    Req.Test.stub(DigitalOcean, stub)

    put_installs_env(
      Keyword.merge(
        [render: Fake, probe: Fake, bootstrap: Fake, fake_delay_ms: 0],
        overrides
      )
    )
  end

  @doc "Merge `overrides` into `config :platform, Platform.Installs` until the test exits."
  def put_installs_env(overrides) do
    previous = Application.get_env(:platform, Installs, [])
    Application.put_env(:platform, Installs, Keyword.merge(previous, overrides))
    on_exit(fn -> Application.put_env(:platform, Installs, previous) end)
  end

  @doc "A root admin user."
  def admin!, do: VaultFixtures.admin!()

  @doc "Create an install through `Installs.create/2`. Returns `{install, token}`."
  def create_install!(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          "business_name" => "Acme Bakery",
          "owner_email" => "owner@acme-bakery.example.test",
          "region" => "nyc3"
        },
        attrs
      )

    {:ok, %{install: install, status_token: token}} = Installs.create(admin!(), attrs)
    {install, token}
  end

  @doc "Wait until `fun.()` is truthy (or fail after `timeout_ms`)."
  def eventually(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline do
          ExUnit.Assertions.flunk("condition never held")
        else
          Process.sleep(10)
          do_eventually(fun, deadline)
        end

      value ->
        value
    end
  end
end
