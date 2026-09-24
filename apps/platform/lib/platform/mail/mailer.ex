defmodule Platform.Mail.Mailer do
  @moduledoc """
  The one module that sends mail (task 01a0cf21-29ba-7001-8690-3c59d6cb17c6
  stage 2).

  The adapter is `Swoosh.Adapters.SMTP`, set in `config/runtime.exs` for
  dev and prod; `config/test.exs` sets a recording test adapter. Relay, port,
  TLS mode, username and password are NOT application config: every send
  passes them as `deliver/2` overrides built by `Platform.Mail.Deliverer`
  from the resolved account and its Vault secret, so two accounts can never
  share a relay by accident.

  Nothing outside `lib/platform/mail/` may reference Swoosh or gen_smtp, and
  only `Platform.Mail.Deliverer` calls this module — enforced by
  `test/platform/mail/single_sender_guard_test.exs`.
  """
  use Swoosh.Mailer, otp_app: :platform
end
