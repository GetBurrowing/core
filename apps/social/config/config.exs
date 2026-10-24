# Social's dev and test config (ADR 0055): core's config, imported, plus this
# module's registration. Core's config never sets `:extensions`; an install
# gets Social only from a config like this one (the with-modules release
# host's, or this module's own for its tests).
import Config

import_config "../../platform/config/config.exs"

config :platform, :extensions, [Platform.Social.Extension]

# The publisher adapter (Social 2/7). Config selects one only for dev and
# test, the Fake. prod selects through the SOCIAL_PUBLISHER env var, read by
# `Platform.Social.RuntimeConfig` at boot in `Platform.Social.Application.start/2`
# (not a runtime.exs: the release runs core's, which never names Social).
# `SOCIAL_PUBLISHER=zernio` selects `Platform.Social.Publisher.Zernio`; unset,
# `Platform.Social.Publisher.impl/0` answers `{:error, :publisher_not_configured}`.
if config_env() in [:dev, :test] do
  config :social, :publisher, Platform.Social.Publisher.Fake
end

# Per-account publish limit (Platform.Social.RateLimit), read on every call.
# The default matches the vendor's 25 posts/hour per-account velocity cap.
config :social, :rate_limit, per_window: 25, window_ms: 3_600_000

# How often Platform.Social.PublishRetry re-publishes rate-limited posts whose
# window has ended (task 01a165f1).
config :social, :publish_retry, interval_ms: 60_000

# Clip Studio 2/9: the server-side undo window between a human's clip
# approval and its posts' publish (Platform.Social.ClipPublish), and how often
# it sweeps for due posts besides the timer each approval arms.
config :social, :clip_publish, window_ms: 8_000, interval_ms: 30_000

# Dev only: shrink the limit and the retry sweep to watch a rate-limited post
# go out without waiting an hour. Unset, the defaults above stand.
if config_env() == :dev do
  env_int = fn name, default ->
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  config :social, :rate_limit,
    per_window: env_int.("SOCIAL_RATE_LIMIT_PER_WINDOW", 25),
    window_ms: env_int.("SOCIAL_RATE_LIMIT_WINDOW_MS", 3_600_000)

  config :social, :publish_retry,
    interval_ms: env_int.("SOCIAL_PUBLISH_RETRY_INTERVAL_MS", 60_000)
end

# Tests start their own PublishRetry with start_supervised!/1 and call
# sweep_now/1; the application's instance sets no timer, so it never queries
# outside a test's sandbox.
if config_env() == :test do
  config :social, :publish_retry, interval_ms: :infinity

  # The same for ClipPublish: no timers and no boot sweep in the
  # application's instance; tests run their own and call sweep_now/2.
  config :social, :clip_publish,
    window_ms: 8_000,
    interval_ms: :infinity,
    timers: false,
    boot_sweep: false
end

# How long a connect invite link stays usable (task 01a14ce1), in days.
# `Platform.Social.create_invite/5` reads it when no ttl is passed.
config :social, :invite_ttl_days, 7

# The Zernio adapter (Social 2/7 stage 4) is NOT selected by any config file:
# prod selects it with SOCIAL_PUBLISHER=zernio at boot (above), and the
# optional SOCIAL_ZERNIO_BASE_URL overrides its base URL the same way. Its
# tests select it per test, and every request goes to a Req.Test stub, never
# the network. Config holds only the base URL and Req options, never a key
# (that is in the Vault at `social:zernio:api_key`).
if config_env() == :test do
  config :social, Platform.Social.Publisher.Zernio, base_url: "https://zernio.test/api"
  config :social, :zernio_req_options, plug: {Req.Test, Platform.Social.Publisher.Zernio}
end

# The clip renderer (Social 5/7). Default (dev, prod) is plain ffmpeg
# (`Platform.Social.Renderer.Ffmpeg`); tests use the Fake (test/support),
# and the real-ffmpeg tests call the Ffmpeg module directly.
if config_env() == :test do
  config :social, :renderer, Platform.Social.Renderer.Fake
end

# The composer's model seam (Composer 1/5, task 01a14aca): DATA, read on
# every call by `Platform.Social.Composer.config/1`, which falls back to the
# same values when unset (a release whose config does not set it). The
# drafting agent is whoever `Platform.Roles.assignee_for/1` resolves for
# `responsibility_key`; no assignee means every column answers
# `{:error, :no_drafting_agent}`. `model: nil` keeps the agent's own model;
# an experiment arm on `social.composer.adaptation` may name another.
config :social, :composer,
  provider: Platform.Agents.Providers.Anthropic,
  responsibility_key: "social.composer",
  temperature: 0.7,
  max_tokens: 1500,
  model: nil
