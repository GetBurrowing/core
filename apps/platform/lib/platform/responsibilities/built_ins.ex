defmodule Platform.Responsibilities.BuiltIns do
  @moduledoc """
  Platform-owned built-in responsibility providers (ADR-0041 M8 stage 2).

  M1 already exposes the registration plumbing (`register_all/1` →
  `upsert_by_key/1`); this module is the canonical *list* of providers
  the platform itself ships, suitable to be passed straight to the
  Registry's `:providers` option (or wired through
  `config :platform, Platform.Responsibilities, providers: ...`).

  Concrete callers:

    * `Platform.Responsibilities.Registry` reads
      `Application.get_env(:platform, Platform.Responsibilities)[:providers]`
      on `init/1`. `config/config.exs` sets that key to
      `Platform.Responsibilities.BuiltIns.providers/0` so a fresh boot
      always upserts the built-ins before any responsibility-trigger
      surface (cron tick, event_topic subscriber, chat_pattern matcher)
      walks the table.

    * Tests can opt-in by passing
      `providers: Platform.Responsibilities.BuiltIns.providers()` when
      starting a per-case Registry — no need to know which modules
      ship today.

  ## Adding a built-in

  Define a module under `Platform.Responsibilities.Handlers.*` that
  implements `Platform.Responsibilities.Provider`, then add it to
  `providers/0` below. The next boot picks it up; existing rows whose
  declared content drifted are replaced via `upsert_by_key/1`'s
  `ON CONFLICT (key) DO UPDATE` path (operator-set `enabled` is preserved).
  """

  alias Platform.Responsibilities.Handlers

  @doc """
  Return the ordered list of platform-owned responsibility provider
  modules. Order matters only as a tiebreaker for duplicate keys (last
  writer wins through the registry's idempotent upsert); platform
  built-ins must not collide with each other, so ordering is cosmetic.
  """
  @spec providers() :: [module()]
  def providers do
    [
      Handlers.DailySummary,
      Handlers.Dreaming,
      Handlers.MeetingSummarize
    ]
  end
end
