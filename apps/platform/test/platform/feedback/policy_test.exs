defmodule Platform.Feedback.PolicyTest do
  @moduledoc """
  Task 01a1a6a5 stage 1: an unset or blank `FEEDBACK_POLICY` means the
  capability is ON (`:quarantined`), an explicit `disabled` or any explicit
  unknown value means OFF, and `explicit?/0` (the intake gate) is true only
  for an explicitly set `quarantined` or `trusted`.

  async: false — flips `:feedback_policy`.
  """
  use ExUnit.Case, async: false

  alias Platform.Feedback.Policy

  setup do
    saved = Application.fetch_env(:platform, :feedback_policy)

    on_exit(fn ->
      case saved do
        {:ok, v} -> Application.put_env(:platform, :feedback_policy, v)
        :error -> Application.delete_env(:platform, :feedback_policy)
      end
    end)

    :ok
  end

  defp set_policy(value), do: Application.put_env(:platform, :feedback_policy, value)

  test "unset means enabled and quarantined, but not explicit" do
    Application.delete_env(:platform, :feedback_policy)

    assert Policy.enabled?()
    assert Policy.mode() == :quarantined
    assert Policy.initial_trust() == {:ok, "quarantined"}
    refute Policy.explicit?()
  end

  test "nil and blank values mean the unset default" do
    for value <- [nil, "", "   ", "\n"] do
      set_policy(value)

      assert Policy.enabled?(), "#{inspect(value)} disabled it"
      assert Policy.mode() == :quarantined
      refute Policy.explicit?(), "#{inspect(value)} counted as explicit"
    end
  end

  test "an explicit disabled turns the capability off" do
    for value <- ["disabled", " Disabled ", :disabled] do
      set_policy(value)

      refute Policy.enabled?()
      assert Policy.mode() == :disabled
      refute Policy.explicit?()
      assert Policy.initial_trust() == {:error, :disabled}
    end
  end

  test "an explicit unknown value fails closed" do
    for value <- ["enabeld", "on", "true", "enabled", "QUARANTINE", "trust", "1"] do
      set_policy(value)

      refute Policy.enabled?(), "#{inspect(value)} enabled it"
      assert Policy.mode() == :disabled
      refute Policy.explicit?(), "#{inspect(value)} counted as explicit"
    end
  end

  test "explicit quarantined and trusted are explicit" do
    set_policy("quarantined")
    assert Policy.enabled?()
    assert Policy.mode() == :quarantined
    assert Policy.explicit?()

    set_policy(" Trusted ")
    assert Policy.enabled?()
    assert Policy.mode() == :trusted
    assert Policy.explicit?()
    assert Policy.initial_trust() == {:ok, "trusted"}
  end

  test "normalize/1 stays fail-closed on its own" do
    assert Policy.normalize(nil) == :disabled
    assert Policy.normalize("") == :disabled
    assert Policy.normalize("enabeld") == :disabled
    assert Policy.normalize("trusted") == :trusted
  end
end
