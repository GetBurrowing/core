defmodule Platform.Secretary.PromptTest do
  @moduledoc """
  The prompt carries only what the person may read (task 01a1b721 stage 3).
  Built for C in the stage-1 readability world, it holds the open channel C
  is not in and none of the secrets; built for A it holds A's own DM and
  group (the positive control).

  Mutant this names: drop the Inputs readability filter (M15) -> "C's prompt
  holds none of the secrets" goes red.
  """
  use Platform.DataCase, async: false

  import Platform.SecretaryFixtures

  alias Platform.Experiments.Surfaces.SecretaryPolicy
  alias Platform.Secretary.{Context, Inputs, Prompt}
  alias Platform.Secretary.Model.Host

  @since ~U[2000-01-01 00:00:00Z]

  defp prompt_for(user) do
    Prompt.build(
      user,
      Inputs.gather(user, @since),
      Context.for_user(user),
      SecretaryPolicy.control()
    )
  end

  setup do
    readability_world!()
  end

  test "C's prompt holds the open channel and none of the secrets", ctx do
    prompt = prompt_for(ctx.c)

    assert prompt =~ "open-text"
    assert prompt =~ "allowed-xyz"

    for secret <- secrets() do
      refute prompt =~ secret, "#{secret} reached C's prompt"
    end
  end

  test "A's prompt holds A's own DM and group (positive control)", ctx do
    prompt = prompt_for(ctx.a)
    assert prompt =~ "dm-secret-xyz"
    assert prompt =~ "grp-secret-xyz"
  end

  test "the INPUTS block is fenced, marked untrusted and parseable", ctx do
    prompt = prompt_for(ctx.c)
    [_, rest] = String.split(prompt, Host.inputs_open() <> "\n", parts: 2)
    [json, _] = String.split(rest, "\n" <> Host.inputs_close(), parts: 2)

    assert %{"today" => _, "brief_max_lines" => 5, "items" => [_ | _] = items} =
             Jason.decode!(json)

    assert Enum.all?(items, &Map.has_key?(&1, "ref_id"))
    assert prompt =~ "untrusted data"
    assert prompt =~ "\"evaluations\""
  end

  test "the same inputs give the same bytes", ctx do
    inputs = Inputs.gather(ctx.c, @since)
    context = Context.for_user(ctx.c)
    now = ~U[2026-11-07 12:00:00Z]

    assert Prompt.build(ctx.c, inputs, context, SecretaryPolicy.control(), now: now) ==
             Prompt.build(ctx.c, inputs, context, SecretaryPolicy.control(), now: now)
  end
end
