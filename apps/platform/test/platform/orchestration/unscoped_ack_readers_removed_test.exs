defmodule Platform.Orchestration.UnscopedAckReadersRemovedTest do
  @moduledoc """
  Task `01a0db63-c4f3`: the unscoped ack readers `stage_acked?/2`,
  `last_stage_ack_at/2` and `last_stage_ack/2` are GONE, not merely unused.

  Any authenticated runtime can write an `execution.acked` row naming any
  stage (`RuntimeChannel` `execution_event` forces only `runtime_id`), so an
  unscoped reader counts a non-owner's ack. No lib code called them, and
  deleting them makes CI's `--warnings-as-errors` compile reject any future
  caller. This file is the runtime half of that guard.

  The `/3` asserts are the POSITIVE CONTROL. `function_exported?/3` answers
  `false` for a module that is not loaded, so without `Code.ensure_loaded!/1`
  every refute below would pass vacuously; the asserts fail in exactly that
  case, and prove the probe can see a function that does exist.
  """
  use ExUnit.Case, async: true

  alias Platform.Orchestration

  test "the unscoped /2 ack readers are not exported, and the scoped /3 readers are" do
    Code.ensure_loaded!(Orchestration)

    assert function_exported?(Orchestration, :last_stage_ack_at, 3)
    assert function_exported?(Orchestration, :last_stage_ack, 3)

    refute function_exported?(Orchestration, :stage_acked?, 2)
    refute function_exported?(Orchestration, :last_stage_ack_at, 2)
    refute function_exported?(Orchestration, :last_stage_ack, 2)
  end
end
