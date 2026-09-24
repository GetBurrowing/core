defmodule Platform.Mail.Config do
  @moduledoc """
  Master switch for the Email module (task 01a0cf21-29ba-7001-8690-3c59d6cb17c6).

  Email is its own env-gated module, not an admin screen. Every part of it —
  the rail tile, the routes, the send path, the IMAP poller, the MCP draft
  tools and the email deploy strategy — reads the flag through `enabled?/0`
  and nothing else.

  ## Fail closed

  The module is on only when `MAIL_ENABLED` is exactly the string `"true"`.
  Unset, `"1"`, `"TRUE"`, `"yes"` and every other value mean off. An absent
  flag is a valid disabled state, so it is deliberately NOT in
  `Platform.Config`'s required-in-prod list.

  ## Injection

  `config :platform, :mail_enabled, <bool>` short-circuits the environment
  read, mirroring `Platform.Meetings.Config.enabled?/0`. `config/test.exs`
  pins it to `false` so the suite is not a function of the host's
  environment; a test that needs the module on flips it with
  `Application.put_env/3` and restores it in `on_exit/1`.
  """

  @spec enabled?() :: boolean()
  def enabled? do
    case Application.fetch_env(:platform, :mail_enabled) do
      {:ok, injected} -> injected == true
      :error -> System.get_env("MAIL_ENABLED") == "true"
    end
  end
end
