defmodule Platform.Feedback.PolicyTest do
  @moduledoc """
  Task 01a1a6a5 stage 1: feedback is OPT-IN. Unset, blank, `disabled` and
  any unknown value (such as the typo `enabeld`) mean `:disabled`; only an
  explicit `quarantined` or `trusted` turns the capability on. `enabled?/0`
  is the one predicate.

  async: false — flips `:feedback_policy`; every test restores it on exit.
  """
  use Platform.DataCase, async: false

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

  test "unset means disabled" do
    Application.delete_env(:platform, :feedback_policy)

    refute Policy.enabled?()
    assert Policy.mode() == :disabled
    assert Policy.initial_trust() == {:error, :disabled}
  end

  test "nil and blank values mean disabled" do
    for value <- [nil, "", "   ", "\n"] do
      set_policy(value)

      refute Policy.enabled?(), "#{inspect(value)} enabled it"
      assert Policy.mode() == :disabled
    end
  end

  test "an explicit disabled turns the capability off" do
    for value <- ["disabled", " Disabled ", :disabled] do
      set_policy(value)

      refute Policy.enabled?()
      assert Policy.mode() == :disabled
      assert Policy.initial_trust() == {:error, :disabled}
    end
  end

  test "an unknown value fails closed" do
    for value <- ["enabeld", "on", "true", "enabled", "QUARANTINE", "trust", "1"] do
      set_policy(value)

      refute Policy.enabled?(), "#{inspect(value)} enabled it"
      assert Policy.mode() == :disabled
    end
  end

  test "quarantined and trusted turn the capability on" do
    set_policy("quarantined")
    assert Policy.enabled?()
    assert Policy.mode() == :quarantined
    assert Policy.initial_trust() == {:ok, "quarantined"}

    set_policy(" Trusted ")
    assert Policy.enabled?()
    assert Policy.mode() == :trusted
    assert Policy.initial_trust() == {:ok, "trusted"}
  end

  test "there is one predicate: explicit?/0 no longer exists" do
    Code.ensure_loaded!(Policy)
    refute function_exported?(Policy, :explicit?, 0)
  end

  test "normalize/1 is fail-closed on its own" do
    assert Policy.normalize(nil) == :disabled
    assert Policy.normalize("") == :disabled
    assert Policy.normalize("enabeld") == :disabled
    assert Policy.normalize("trusted") == :trusted
  end
end
