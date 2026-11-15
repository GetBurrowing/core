# Goals' dev and test config (ADR 0055, task 01a1dfc0): core's config,
# imported, plus this module's registration. Core's config never sets
# `:extensions`; an install gets Goals only from a config like this one (the
# with-modules release host's, or this module's own for its tests).
#
# GOALS_ENABLED is NOT read here: `Platform.Goals.RuntimeConfig` reads it at
# boot in `Platform.Goals.Application.start/2`.
import Config

import_config "../../platform/config/config.exs"

config :platform, :extensions, [Platform.Goals.Extension]
