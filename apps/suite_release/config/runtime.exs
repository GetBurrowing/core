# Core's runtime config, evaluated in place for this host's Mix runs (dev
# and test). Mix evaluates only the CURRENT project's config/runtime.exs, and
# refuses `import_config/1` inside one, so the module reads core's file with
# `Config.Reader` and applies every key it sets. The result is exactly the
# runtime config core's own `mix test` sees.
#
# Play's own runtime settings (GAME_STREAM_ENABLED and the TURN block) are
# NOT here: `Platform.GameStream.Application.start/2` reads them, so a release
# (whose runtime config is core's file, via `runtime_config_path`) and a Mix
# run read them the same way
# (`docs/decisions/0055-extension-contract-and-build-time-modules.md § 8. Configuration that belongs to a module`).
import Config

core_runtime = Path.expand("../../platform/config/runtime.exs", __DIR__)

for {app, settings} <-
      Config.Reader.read!(core_runtime, env: config_env(), target: config_target()) do
  config app, settings
end
