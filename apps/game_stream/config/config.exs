# Play's dev and test config (ADR 0055, task 01a0ee08 stage 3): core's config,
# imported, plus this module's registration. Core's config never sets
# `:extensions`; an install gets Play only from a config like this one (the
# with-Play release host's, or this module's own for its tests).
import Config

import_config "../../platform/config/config.exs"

config :platform, :extensions, [Platform.GameStream.Extension]
