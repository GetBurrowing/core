defmodule Platform.Responsibilities.NoEnvFlagGatesTest do
  @moduledoc """
  Source-scanning regression sweep. Fails if any file on the
  responsibility-firing surface reintroduces the anti-pattern of
  gating responsibility execution on an env-var boolean:

      Application.get_env(:platform, :some_flag, true|false)

  This anti-pattern was removed across three stages of task
  `019f4447-54fc-7d77-a67c-6494133b4bb7` (2026-07-08):
  meeting-producer runtime, architect cron sweep, and
  responsibility-router dual-write shim. This test locks that
  removal in place so a future refactor cannot quietly re-add a
  boolean env gate in front of responsibility firing.

  ## What counts as "responsibility-firing"

  Anything on the path from a Suite-side signal to handler
  invocation:

    * `intent_classifier.ex` / `summarizer_sweeper.ex` — meeting
      producers that emit responsibility signals.
    * `system_event_scheduler.ex` — cron-shaped producer for
      time-based responsibilities.
    * `responsibilities/router.ex` — the demultiplexer that hands
      a signal to a handler.
    * `responsibilities/handlers/*.ex` — the handlers themselves.
    * `security/sweeper.ex` + `security/llm_enrichment.ex` — the
      security-guard producer + its enrichment step.

  ## Why *boolean* defaults specifically

  Only `Application.get_env(:platform, :key, true|false)` trips.
  Env reads with integer, module, or tuple defaults are fine —
  those configure *how* infra behaves, not *whether* responsibility
  firing happens. Compare:

    * `historian_threshold_tokens` (integer default) — tunes when
      Historian fires; does not gate the firing surface.
    * `security_llm_enrichment_provider` (module default) — swaps
      the provider module; does not gate the pipeline.
    * `start_meeting_intent_classifier` (boolean, allowed) — gates
      **infra availability** (whether the GenServer starts at
      all), not per-signal responsibility firing. Reads of these
      are permitted via `@allowed_config_keys`.

  ## Adding an allow-list entry

  Do NOT expand `@allowed_config_keys` without leaving a comment
  on the call site explaining why the key gates infra
  availability rather than responsibility firing.
  """
  use ExUnit.Case, async: true

  # test/platform/responsibilities → apps/platform
  @app_root Path.expand("../../..", __DIR__)

  # Files (and directories, walked recursively for `*.ex`) that
  # make up the responsibility-firing surface.
  @responsibility_firing_paths [
    "lib/platform/meetings/intent_classifier.ex",
    "lib/platform/agents/system_event_scheduler.ex",
    "lib/platform/responsibilities/router.ex",
    "lib/platform/responsibilities/handlers",
    "lib/platform/security/sweeper.ex",
    "lib/platform/security/llm_enrichment.ex",
    "lib/platform/meetings/summarizer_sweeper.ex"
  ]

  # Env-var config keys that legitimately gate infra availability,
  # NOT responsibility firing. Reads of these are permitted. See
  # module-doc for the criteria for adding a new entry.
  @allowed_config_keys ~w(
    historian_threshold_tokens
    historian_debounce_ms
    check_interval_ms
    start_meeting_intent_classifier
    start_meeting_intent_dispatcher
    start_responsibility_router
    llm_provider_module
  )

  # Matches `Application.get_env(:platform, :SOMEKEY, true|false)`
  # across optional whitespace / newlines. Only trips on the
  # literal boolean defaults — integer / module / tuple / attribute
  # defaults never match.
  @boolean_flag_pattern ~r/Application\.get_env\(\s*:platform\s*,\s*:([a-z_][a-zA-Z0-9_]*)\s*,\s*(true|false)\s*\)/s

  test "no responsibility-firing code path is gated on an env-var boolean" do
    offenders =
      @responsibility_firing_paths
      |> Enum.flat_map(&expand_path/1)
      |> Enum.flat_map(&scan_file/1)
      |> Enum.reject(fn {_path, key, _default} -> key in @allowed_config_keys end)

    assert offenders == [], format_offender_message(offenders)
  end

  # Expand a plan-relative path (file or directory) into a concrete
  # list of `.ex` files under `@app_root`. Fails loudly if a path
  # in @responsibility_firing_paths no longer exists — that's a
  # signal the sweep list has drifted from the tree.
  defp expand_path(rel) do
    abs = Path.join(@app_root, rel)

    cond do
      File.dir?(abs) ->
        Path.wildcard(Path.join(abs, "**/*.ex"))

      File.regular?(abs) ->
        [abs]

      true ->
        flunk(
          "responsibility-firing path #{inspect(rel)} does not exist at #{abs}. " <>
            "Either the file/dir moved (update @responsibility_firing_paths) " <>
            "or the sweep is out of date."
        )
    end
  end

  defp scan_file(path) do
    source = File.read!(path)

    @boolean_flag_pattern
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.map(fn [key, default] -> {path, key, default} end)
  end

  defp format_offender_message(offenders) do
    lines =
      Enum.map(offenders, fn {path, key, default} ->
        rel = Path.relative_to(path, @app_root)
        "  * #{rel}: Application.get_env(:platform, :#{key}, #{default})"
      end)

    """
    Detected responsibility-firing code path(s) gated on a boolean env-var flag:

    #{Enum.join(lines, "\n")}

    This is the anti-pattern task 019f4447 removed across three stages
    (meeting-producer runtime, architect cron sweep, responsibility
    router dual-write). Responsibility firing must NOT be gated on
    `Application.get_env(:platform, :some_key, true|false)`.

    If the flag legitimately gates **infra availability** (e.g.
    whether a GenServer starts at all) and NOT responsibility firing
    per signal, add its key to `@allowed_config_keys` in this test
    module AND leave a comment on the call site explaining why.

    If it gates responsibility firing: remove the flag. Responsibility
    routing is now always-on.
    """
  end
end
