# Module rig (ADR 0055 stage 4, task 01a0ee08): what `mix ecto.migrations`
# prints, from inside a release: every version over every migrations path
# the build knows (core's first, then each module's), with its status and
# name. A version in schema_migrations whose file this build lacks reads
# `** FILE NOT FOUND **`, which is the one thing the prod-like case forbids
# for the with-module build.
repo = Platform.Repo
paths = Platform.Release.migrations_paths(repo)

IO.puts("RIG paths=#{Enum.join(paths, ",")}")

for {status, version, name} <- Ecto.Migrator.migrations(repo, paths) do
  IO.puts("RIG migration #{status} #{version} #{name}")
end
