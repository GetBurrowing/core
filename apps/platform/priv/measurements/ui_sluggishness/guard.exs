# Env guard for seed.exs (task 01a13884 stage 1).
#
# Evaluates to a one-arity function taking `{mix_env, mix_env_var}` and
# returning `:ok` only for a dev BEAM. It is a separate file so the ExUnit
# guard test can drive BOTH branches (refuse and allow) without running the
# seed: `mix run` under MIX_ENV=test escapes the Ecto sandbox and writes
# straight into the test database.
fn {mix_env, mix_env_var} ->
  cond do
    mix_env != :dev ->
      raise "ui_sluggishness seed refused: Mix.env() is #{inspect(mix_env)}, " <>
              "it only runs under :dev (MIX_ENV=test escapes the sandbox and pollutes the test DB)"

    mix_env_var == "test" ->
      raise "ui_sluggishness seed refused: MIX_ENV=test is set in the environment"

    true ->
      :ok
  end
end
