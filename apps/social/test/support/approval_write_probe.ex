defmodule Platform.SocialApprovalWriteProbe do
  @moduledoc false

  # Only this caller's attempted writes, including writes later rolled back.
  # Store SQL shape, never parameters, and detach before returning.
  def capture(fun) do
    owner = self()
    ref = make_ref()
    handler = {__MODULE__, ref}

    :ok =
      :telemetry.attach(handler, [:platform, :repo, :query], &__MODULE__.record/4, {owner, ref})

    try do
      result = fun.()
      {result, drain(ref, [])}
    after
      :telemetry.detach(handler)
    end
  end

  def record(_event, _measurements, %{query: query}, {owner, ref}) do
    if self() == owner and
         Regex.match?(
           ~r/\A(?:UPDATE|INSERT INTO|DELETE FROM) "(?:social_approval_cards|social_posts|social_post_events)"/,
           query
         ) do
      send(owner, {ref, query})
    end
  end

  defp drain(ref, queries) do
    receive do
      {^ref, query} -> drain(ref, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end
