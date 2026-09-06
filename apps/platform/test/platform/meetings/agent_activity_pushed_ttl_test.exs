defmodule Platform.Meetings.AgentActivityPushedTtlTest do
  @moduledoc """
  The pushed-state ttl is CONFIGURATION, not a compiled constant (task
  `01a07400` stage 1).

  A separate module, and `async: false`, on purpose.
  `Application.put_env/3` is process-global: an async test that flipped
  `:meeting_agent_pushed_ttl_ms` would change the default under every
  concurrently running test that pushed a state without naming a ttl, and
  the failure would land somewhere else and look like a flake. The rest of
  the pushed-state coverage lives in `agent_activity_test.exs`, stays
  `async: true`, and always passes `ttl_ms:` explicitly for exactly that
  reason.

  What is pinned here is the seam, not the number. The compiled default is
  a placeholder: choosing it needs the agent think-time distribution from
  task `01a07400-64bd`, which had not reported when this shipped. So these
  tests assert that the key is read and honoured, and that the default's
  relationship to `ceiling_seconds/0` holds — never that the default equals
  some particular figure, which would turn the placeholder into the
  contract and make the eventual tuning a test edit.
  """
  use ExUnit.Case, async: false

  alias Platform.Meetings.AgentActivity

  @key :meeting_agent_pushed_ttl_ms

  setup do
    previous = Application.fetch_env(:platform, @key)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, @key, value)
        :error -> Application.delete_env(:platform, @key)
      end
    end)

    :ok
  end

  test "the ttl comes from application config, not from a literal in the source" do
    Application.put_env(:platform, @key, 4_242)
    assert AgentActivity.pushed_ttl_ms() == 4_242

    Application.put_env(:platform, @key, 9_999)
    assert AgentActivity.pushed_ttl_ms() == 9_999
  end

  test "a push with no explicit ttl takes the configured value" do
    Application.put_env(:platform, @key, 7_777)

    meeting_id = Platform.Types.UUIDv7.generate()
    agent_id = Platform.Types.UUIDv7.generate()

    {:ok, entry} = AgentActivity.push(meeting_id, agent_id, :thinking)
    assert entry.ttl_ms == 7_777

    AgentActivity.clear_pushed(meeting_id, agent_id)
  end

  # A row carries the ttl it was pushed with. Otherwise a deploy that
  # shortened the key would retroactively expire claims already made, and
  # one that lengthened it would extend a claim a dead runtime made an hour
  # ago — the ttl has to be a property of the declaration, not of the read.
  test "a row keeps the ttl it was pushed with when the config later changes" do
    Application.put_env(:platform, @key, 60_000)

    meeting_id = Platform.Types.UUIDv7.generate()
    agent_id = Platform.Types.UUIDv7.generate()
    t0 = ~U[2099-03-01 12:00:00Z]

    {:ok, entry} = AgentActivity.push(meeting_id, agent_id, :thinking, now: t0)
    assert entry.ttl_ms == 60_000

    Application.put_env(:platform, @key, 1)

    assert %{ttl_ms: 60_000} = AgentActivity.pushed(meeting_id, agent_id, t0)

    assert %{state: :thinking} =
             AgentActivity.pushed(meeting_id, agent_id, DateTime.add(t0, 30, :second))

    AgentActivity.clear_pushed(meeting_id, agent_id)
  end

  # Zero or negative would expire every push on the very next read, which is
  # indistinguishable from the feature being switched off and is never what
  # setting this key means. Falling back to the default is the honest
  # reading of a nonsense value.
  test "a non-positive or non-integer configured ttl falls back to the default" do
    Application.delete_env(:platform, @key)
    default = AgentActivity.pushed_ttl_ms()

    for nonsense <- [0, -1, "30000", nil, 1.5] do
      Application.put_env(:platform, @key, nonsense)

      assert AgentActivity.pushed_ttl_ms() == default,
             "#{inspect(nonsense)} was accepted as a ttl"
    end
  end

  # The one property the placeholder default must have. A pushed state
  # pre-empts the 120-second ceiling, so a default ttl at or above the
  # ceiling would let a dead runtime read `:thinking` for longer than it
  # would have read `:computing` — the feature making the stall WORSE.
  # Asserting the relationship rather than the number leaves task
  # `01a07400-64bd` free to set any sane value without editing a test.
  test "the default ttl is comfortably shorter than the stall ceiling" do
    Application.delete_env(:platform, @key)

    ceiling_ms = AgentActivity.ceiling_seconds() * 1_000

    assert AgentActivity.pushed_ttl_ms() > 0
    assert AgentActivity.pushed_ttl_ms() < ceiling_ms
  end
end
