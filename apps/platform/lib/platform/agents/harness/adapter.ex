defmodule Platform.Agents.Harness.Adapter do
  @moduledoc """
  A harness adapter maps the abstract `Harness.Config` to the files one agent
  harness reads, and back. Paths are relative to the agent root.

  `known_paths/0` tags every glob: `:plain` (safe to show), `:secret_bearing`
  (may hold secret values next to config; only `redact/2` output leaves the
  machine) or `:secret` (never read, written, or shown).
  """

  alias Platform.Agents.Harness.Config

  @type tag :: :plain | :secret_bearing | :secret

  @callback harness() :: String.t()
  @callback concepts() :: [atom()]
  @callback known_paths() :: [{String.t(), tag()}]
  @callback instructions_path() :: String.t()
  @callback settings_path() :: String.t()
  @doc "The non-empty content a new native agent's settings file starts with."
  @callback settings_seed() :: binary()
  @callback render(Config.t()) :: [{String.t(), binary()}]
  @callback parse([{String.t(), binary()}]) :: {:ok, Config.t()} | {:error, term()}
  @callback redact(String.t(), binary()) :: {binary(), [String.t()]}
  @callback restart_resumes?() :: boolean()
end
