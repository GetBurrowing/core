# Core's runtime config, evaluated in place for this module's Mix runs (dev
# and test), exactly as Play's `apps/game_stream/config/runtime.exs` does.
# Mix evaluates only the CURRENT project's config/runtime.exs and refuses
# `import_config/1` inside one, so the module reads core's file with
# `Config.Reader` and applies every key it sets
# (`docs/decisions/0055-extension-contract-and-build-time-modules.md § 8. Configuration that belongs to a module`).
import Config

core_runtime = Path.expand("../../platform/config/runtime.exs", __DIR__)

for {app, settings} <-
      Config.Reader.read!(core_runtime, env: config_env(), target: config_target()) do
  config app, settings
end
