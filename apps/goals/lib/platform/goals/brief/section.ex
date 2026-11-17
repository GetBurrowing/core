defmodule Platform.Goals.Brief.Section do
  @moduledoc "Optional daily brief adapter (task 01a1dfc1-abcc), silent without goals.use."
  alias Platform.Goals

  def prepare(user_id, date) do
    with {:ok, user} <- reader(user_id),
         {:ok, %{new: count}} <- Goals.prepare_brief(user, date),
         do: count,
         else: (_ -> 0)
  rescue
    _ -> 0
  end

  def summary(user_id, date) do
    with {:ok, user} <- reader(user_id),
         {:ok, %{total: total} = summary} <- Goals.brief_summary(user, date),
         true <- total > 0,
         do: summary,
         else: (_ -> nil)
  rescue
    _ -> nil
  end

  defp reader(user_id) do
    with true <- Goals.enabled?(),
         {:ok, id} <- Ecto.UUID.cast(user_id),
         %Platform.Accounts.User{} = user <- Platform.Accounts.get_user(id),
         true <- Platform.Goals.Visibility.may_use?(user),
         do: {:ok, user},
         else: (_ -> {:error, :not_found})
  end
end
