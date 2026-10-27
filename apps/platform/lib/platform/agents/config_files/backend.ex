defmodule Platform.Agents.ConfigFiles.Backend do
  @moduledoc """
  One agent's config files, wherever they live. Both backends return the
  same shapes; `Platform.Agents.ConfigFiles` is the only caller and has already
  authorized and validated the path.

    * `list/1` -> `{:ok, [%{path, sha256, secret?}]}`
    * `read/2` -> `{:ok, %{content, sha256}}` (content as stored; redaction
      is applied by the caller)
    * `write/4` -> `{:ok, sha256} | {:conflict, current_sha256 | nil} | {:error, reason}`
    * `set_secret/4` -> `{:ok, sha256} | {:conflict, sha256} | {:error, reason}`
    * `delete/3` -> `{:ok, nil} | {:conflict, current_sha256} | {:error, reason}`
  """

  alias Platform.Agents.ConfigFiles.Access

  @callback list(Access.ctx()) :: {:ok, [map()]} | {:error, term()}
  @callback read(Access.ctx(), String.t()) ::
              {:ok, %{content: binary(), sha256: String.t()}} | {:error, term()}
  @callback write(Access.ctx(), String.t(), binary(), String.t() | nil) ::
              {:ok, String.t()} | {:conflict, String.t() | nil} | {:error, term()}
  @callback set_secret(Access.ctx(), String.t(), String.t(), String.t()) ::
              {:ok, String.t()} | {:conflict, String.t() | nil} | {:error, term()}
  @callback delete(Access.ctx(), String.t(), String.t() | nil) ::
              {:ok, nil} | {:conflict, String.t() | nil} | {:error, term()}
end
