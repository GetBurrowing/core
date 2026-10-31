defmodule Platform.Installs.BootstrapTest do
  @moduledoc """
  Task 01a10315 stage 6 round 2: every bootstrap-admin call names the
  install's primary host, so the sign-in link it writes is core's hand-over
  route (`/auth/handover`), which lands the owner in Burrow at
  `/setup/connect-ai`. Only the `final` step (with a secret) registers the
  OIDC client.
  """
  use ExUnit.Case, async: true

  alias Platform.Installs.Bootstrap
  alias Platform.Installs.Install

  @install %Install{owner_email: "owner@acme.example.test", primary_host: "acme.example.test"}

  test "a reveal re-mint passes --primary and no OIDC secret" do
    args = Bootstrap.Python.args(@install, "auth.acme.example.test", "/k", "/l", nil)

    assert args ==
             ~w(bootstrap-admin --base https://auth.acme.example.test --api-key-file /k) ++
               ~w(--email owner@acme.example.test --link-file /l --primary acme.example.test)
  end

  test "the final step also registers the OIDC client" do
    args = Bootstrap.Python.args(@install, "auth.acme.example.test", "/k", "/l", "/s")
    assert Enum.take(args, -4) == ~w(--primary acme.example.test --oidc-secret-file /s)
  end
end
