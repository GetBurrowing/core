defmodule Platform.RootOrgAdminEmailDomainTest do
  @moduledoc """
  Pins the auto-admin email rule to `config :platform, :root_org_admin_email_domain`
  rather than a hardcoded `@acme.test`-style suffix (task 01a081c2 stage 2), and
  proves the key itself carries no hardcoded fallback domain anywhere in the
  shared `config/config.exs` (task 01a068f6 stage 1 — renamed from
  `:admin_email_domain`).

  ## Why a separate file and not `tenancy_test.exs`

  `:root_org_admin_email_domain` is application env, which is global to the
  node. `tenancy_test.exs` is `async: true`, and so is `accounts_test.exs`,
  which asserts that a brand-new `@acme.test` signup gets an admin
  membership. Overriding the key from inside an async module would let a
  concurrently running case observe the override and go red intermittently,
  in a test file nobody touched. `async: false` modules run after every
  async one, serially, so the override is only ever visible to the case
  that set it. Same reasoning and same shape as stage 1's
  `root_org_slug_test.exs`.

  The existing default-domain assertions in `tenancy_test.exs` are left untouched:
  `config/test.exs` pins `:root_org_admin_email_domain` to `"acme.test"`
  as a test-environment convenience (mirroring `config/dev.exs`), so they
  still cover the same effective default. What changed is where that
  default lives — no longer in the shared `config/config.exs` that every
  fresh production install would otherwise inherit.

  ## Why "example.net"

  It stands in for a real second install (task 01a14b9e stage 5 replaced
  the real domains with placeholders). A second install runs its own
  database, and before task 01a081c2 every address on the first install's
  domain that logged in there was auto-promoted to admin on somebody
  else's Suite, with no way to turn that off short of editing the image.

  ## What each case would do before task 01a081c2

  `derive_role_from_email("alice@acme.test")` returned `:admin`
  unconditionally, so every configuration below would have failed at that
  assertion. The empty-string and deleted-key cases additionally pin the
  choice that unset means NOBODY is auto-admined: never everybody, and
  never a silent fall back to the first install's domain — including in an environment
  (dev/test) whose config file happens to pin one, since the deleted-key
  case removes the key from the live Application env entirely rather than
  merely not-overriding it.
  """

  use ExUnit.Case, async: false

  alias Platform.Tenancy

  # Restore whatever the surrounding environment had, including "the key was
  # absent", so a case that deletes it cannot leak that absence forward.
  defp put_domain(value) do
    previous = Application.fetch_env(:platform, :root_org_admin_email_domain)

    on_exit(fn ->
      case previous do
        {:ok, prior} -> Application.put_env(:platform, :root_org_admin_email_domain, prior)
        :error -> Application.delete_env(:platform, :root_org_admin_email_domain)
      end
    end)

    case value do
      :delete -> Application.delete_env(:platform, :root_org_admin_email_domain)
      domain -> Application.put_env(:platform, :root_org_admin_email_domain, domain)
    end
  end

  describe "a configured domain other than the fixture default" do
    setup do
      put_domain("example.net")
      :ok
    end

    test "a fixture-default address is an ordinary member on somebody else's install" do
      assert Tenancy.derive_role_from_email("alice@acme.test") == :member
    end

    test "the configured domain is the one that derives admin" do
      assert Tenancy.derive_role_from_email("bob@example.net") == :admin
    end

    test "the host comparison stays case-insensitive and suffix-anchored" do
      assert Tenancy.derive_role_from_email("BOB@EXAMPLE.NET") == :admin
      assert Tenancy.derive_role_from_email("bob@eu.example.net") == :member
      assert Tenancy.derive_role_from_email("example.net@gmail.com") == :member
    end

    # Not part of the red-against-main evidence: main escaped the dot in its
    # compile-time literal, so these were `:member` there too. This is a
    # forward guard. Swapping `String.ends_with?/2` for
    # `Regex.compile!("@" <> domain <> "$")` makes both of these `:admin`,
    # because a dot in a CONFIGURED value is then a pattern metacharacter
    # matching any character. Verified: that regex returns true for both.
    test "a dot in the configured domain is a literal, not a wildcard" do
      assert Tenancy.derive_role_from_email("bob@exampleXnet") == :member
      assert Tenancy.derive_role_from_email("bob@example-net") == :member
    end

    test "root_org_admin_email_domain/0 reports the configured value" do
      assert Tenancy.root_org_admin_email_domain() == "example.net"
    end
  end

  describe "a blank configured domain disables auto-admin" do
    setup do
      put_domain("")
      :ok
    end

    test "nobody derives admin, including the shipped default's domain" do
      assert Tenancy.derive_role_from_email("alice@acme.test") == :member
      assert Tenancy.derive_role_from_email("bob@example.net") == :member
      assert Tenancy.derive_role_from_email("carol@anywhere.example") == :member
    end

    test "root_org_admin_email_domain/0 collapses blank to nil" do
      assert Tenancy.root_org_admin_email_domain() == nil
    end
  end

  describe "no configured domain at all" do
    setup do
      put_domain(:delete)
      :ok
    end

    test "an unset key auto-admins nobody rather than everybody, even for an email that would have matched if configured" do
      assert Tenancy.derive_role_from_email("alice@acme.test") == :member
      assert Tenancy.derive_role_from_email("bob@example.net") == :member
      assert Tenancy.derive_role_from_email("carol@anywhere.example") == :member
    end

    test "root_org_admin_email_domain/0 reports nil" do
      assert Tenancy.root_org_admin_email_domain() == nil
    end
  end
end
