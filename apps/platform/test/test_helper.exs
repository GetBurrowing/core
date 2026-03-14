ExUnit.start()

if Process.whereis(Platform.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, :manual)
end
