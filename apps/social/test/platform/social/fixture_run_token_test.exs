defmodule Platform.Social.FixtureRunTokenTest do
  @moduledoc """
  Fixture emails carry a per-BEAM-run token so a reused test database does
  not collide on `users_email_index` across runs. A second BEAM cannot be
  started here, so the token function is tested instead: a simulated second
  run (the cached token erased) must produce different emails for the same
  counter value.
  """
  use ExUnit.Case, async: false

  alias Platform.TenancyFixtures

  @key {Platform.TenancyFixtures, :run_token}

  test "the token is 64 random bits of hex and stable within one run" do
    token = TenancyFixtures.run_token()
    assert token =~ ~r/\A[0-9a-f]{16}\z/
    assert TenancyFixtures.run_token() == token
  end

  test "a simulated second run gets a different token, so the same counter gives a different email" do
    first = :persistent_term.get(@key, nil) || TenancyFixtures.run_token()
    on_exit(fn -> :persistent_term.put(@key, first) end)

    email = fn n -> "social-user-#{TenancyFixtures.run_token()}-#{n}@example.com" end
    run_one = email.(7)

    :persistent_term.erase(@key)
    run_two = email.(7)

    assert run_one != run_two
    assert run_two =~ ~r/\Asocial-user-[0-9a-f]{16}-7@example\.com\z/
  end
end
