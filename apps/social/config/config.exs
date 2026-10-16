# Social's dev and test config (ADR 0055): core's config, imported, plus this
# module's registration. Core's config never sets `:extensions`; an install
# gets Social only from a config like this one (the with-modules release
# host's, or this module's own for its tests).
import Config

import_config "../../platform/config/config.exs"

config :platform, :extensions, [Platform.Social.Extension]

# The publisher adapter (Social 2/7). Only dev and test select one, the Fake;
# prod sets NOTHING until a vendor is chosen, so `Platform.Social.Publisher.impl/0`
# answers `{:error, :publisher_not_configured}` there and nothing publishes.
if config_env() in [:dev, :test] do
  config :social, :publisher, Platform.Social.Publisher.Fake
end

# Per-account publish limit (Platform.Social.RateLimit), read on every call.
# The default matches the vendor's 25 posts/hour per-account velocity cap.
config :social, :rate_limit, per_window: 25, window_ms: 3_600_000

# The Zernio adapter (Social 2/7 stage 4) is NOT selected in any env: no
# vendor is chosen and no keys exist. Its tests select it per test, and every
# request goes to a Req.Test stub, never the network. Config holds only the
# base URL and Req options, never a key (that is in the Vault).
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
