defmodule Platform.Responsibilities.Providers do
  @moduledoc """
  The explicit `feature -> provider module` registry (task 019f9b28 stage 2).

  ## What this replaces, and why

  Until this module existed the Router resolved a provider by *deriving*
  its name:

      Module.concat([Platform.Responsibilities.Providers, Macro.camelize(feature)])

  and every consumption point then guarded the result with
  `Code.ensure_loaded?/1`. That is a name convention masquerading as a
  lookup table, and it has one fatal property: **"the module was never
  written" and "this feature deliberately has no provider" are the same
  value.** Both produce an atom that fails `ensure_loaded?`, so both fall
  into the same fallback arm, so both emit the same `Logger.info("no
  output handler for <key>")` line. `architecture.*` sat in that state for
  months — every fire dispatched, every answer was discarded, and nothing
  in the logs distinguished it from `security.*`, which is *supposed* to
  have no provider.

  ## The argued choice

  **Option A — leave resolution alone and just add the missing module.**
  Smallest possible diff; the symptom goes away and the class stays. The
  next feature that ships a handler without a provider shim reproduces the
  bug exactly, and reproduces it silently.

  **Option B — resolve from an explicit map (this module); delete the
  camelize.** Costs one file and a rewrite of the ad-hoc-provider test
  helper. Buys a three-way return — `{:ok, module}` / `{:retired, reason}`
  / `:error` — which is the whole point: a caller can now tell a
  *deliberate* absence from an *accidental* one, and can therefore log
  them differently (Router), fail CI on one and not the other (stage 4),
  and shout at boot about only the accidental kind (stage 3).

  Option B is what shipped. The reasoning above is the part to reject if
  you disagree — the diff is downstream of it.

  ## Retirement is a stated value, not an absence

  `security.*` is in `@retired`, not merely missing from
  `@feature_providers`. `Platform.Security.Sweeper` owns those keys through
  its own `@default_scanner_modules` dispatch table and the handler
  moduledocs say the Router must never fire them. Recording *why* means a
  future reader gets an answer instead of an ambiguity, and means stage 4's
  coverage test can assert the exemption against the Sweeper's real table
  rather than hardcoding a skip list.

  ## The override seam

  `feature_provider/1` consults
  `Application.get_env(:platform, :responsibility_provider_overrides, %{})`
  — a `%{feature_string => module}` map — before the compiled registry.
  This is the supported way to bind a provider that is not a platform
  built-in (tests defining ad-hoc providers, and operators pairing a
  `config :platform, Platform.Responsibilities, providers: [...]` extension
  with its own feature). It is deliberately an *explicit registration*
  rather than a name convention: an override that was never registered
  still returns `:error`, so the distinguishability this module exists to
  create survives the seam.

  `all/0` and `retired/0` expose the compiled maps only — overrides are
  runtime state and must not leak into drift detection.
  """

  alias Platform.Responsibilities.Providers.Architecture
  alias Platform.Responsibilities.Providers.Design
  alias Platform.Responsibilities.Providers.Meetings
  alias Platform.Responsibilities.Providers.Memory
  alias Platform.Responsibilities.Providers.Tasks

  @feature_providers %{
    "architecture" => Architecture,
    "design" => Design,
    "meetings" => Meetings,
    "memory" => Memory,
    "tasks" => Tasks
  }

  @retired %{
    "security" =>
      "superseded by Platform.Security.Sweeper's own scanner dispatch table " <>
        "(@default_scanner_modules in lib/platform/security/sweeper.ex); the security.* " <>
        "handler moduledocs state the Router must never fire them"
  }

  @override_env_key :responsibility_provider_overrides

  @typedoc """
  Three distinguishable outcomes. The whole reason this module exists is
  that `{:retired, _}` and `:error` used to be the same value.
  """
  @type resolution :: {:ok, module()} | {:retired, String.t()} | :error

  @doc """
  Resolve a responsibility's `feature` string to its provider module.

  * `{:ok, module}` — a provider is registered (or overridden) for this feature.
  * `{:retired, reason}` — this feature deliberately has no Router provider,
    and `reason` says who owns it instead.
  * `:error` — nothing is registered. For a platform built-in that is a bug;
    for an ad-hoc / operator-seeded row it is ordinary.

  Non-binary and empty features resolve to `:error` rather than raising —
  the fire sites are inside a plan-submit path and an Ecto transaction, so
  a raise here would be worse than the bug this replaces.
  """
  @spec feature_provider(term()) :: resolution()
  def feature_provider(feature) when is_binary(feature) and feature != "" do
    case Map.fetch(overrides(), feature) do
      {:ok, module} when is_atom(module) and not is_nil(module) -> {:ok, module}
      _ -> compiled_resolution(feature)
    end
  end

  def feature_provider(_feature), do: :error

  @doc """
  The compiled `feature -> provider module` map. Overrides are excluded on
  purpose: drift detection must reason about what the release ships.
  """
  @spec all() :: %{optional(String.t()) => module()}
  def all, do: @feature_providers

  @doc """
  The compiled `feature -> retirement reason` map.
  """
  @spec retired() :: %{optional(String.t()) => String.t()}
  def retired, do: @retired

  defp compiled_resolution(feature) do
    case Map.fetch(@feature_providers, feature) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        case Map.fetch(@retired, feature) do
          {:ok, reason} -> {:retired, reason}
          :error -> :error
        end
    end
  end

  defp overrides do
    case Application.get_env(:platform, @override_env_key) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end
end
