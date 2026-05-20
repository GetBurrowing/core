defmodule Platform.Org.Wiki.ContextTest do
  @moduledoc """
  Tests for `Platform.Org.Wiki.Context` — the budgeted, scope-aware
  preamble assembler (ADR-0041 T4).

  Stage 1 ships only this stub — the module itself lands in stage 2. By
  end of stage 2, `build_preamble/1` and `build_preamble_with_metadata/1`
  exist and a richer table-driven suite replaces the placeholder
  assertion below.
  """
  use Platform.DataCase, async: false

  alias Platform.Org.Wiki

  test "Platform.Org.Wiki.Context.build_preamble/1 is callable (stage 1 stub)" do
    # Stage-1 placeholder: assert only that the module path is reserved
    # for T4 (the actual function is implemented in stage 2). When stage
    # 2 lands, this test is replaced by the full table-driven suite.
    assert {:module, Wiki} = Code.ensure_loaded(Wiki)
    assert Wiki.list_pages([]) == []
  end
end
