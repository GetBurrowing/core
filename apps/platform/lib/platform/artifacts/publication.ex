defmodule Platform.Artifacts.Publication do
  @moduledoc """
  Append-only publication attempt/result record for a single artifact.

  A publication represents one attempt to deliver an artifact to a named
  destination. Attempts are created before delivery begins and then finished as
  `:published` or `:failed`, which gives the UI a deterministic history instead
  of a mutable destination-specific status blob.
  """

  @valid_statuses ~w(requested published failed)a
  @valid_destinations ~w(github docker_registry google_drive preview_route canvas)a

  @enforce_keys [:id, :artifact_id, :destination, :attempt, :status, :started_at]
  defstruct id: nil,
            artifact_id: nil,
            destination: nil,
            attempt: 0,
            status: :requested,
            external_ref: nil,
            result: %{},
            error: nil,
            metadata: %{},
            started_at: nil,
            finished_at: nil

  @type status :: :requested | :published | :failed
  @type destination :: :github | :docker_registry | :google_drive | :preview_route | :canvas

  @type t :: %__MODULE__{
          id: String.t(),
          artifact_id: String.t(),
          destination: destination(),
          attempt: pos_integer(),
          status: status(),
          external_ref: term(),
          result: map(),
          error: term(),
          metadata: map(),
          started_at: DateTime.t(),
          finished_at: DateTime.t() | nil
        }

  @doc "Creates a new reserved publication attempt."
  @spec begin(String.t(), destination(), pos_integer(), keyword()) :: t()
  def begin(artifact_id, destination, attempt, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %__MODULE__{
      id: Ecto.UUID.generate(),
      artifact_id: artifact_id,
      destination: destination,
      attempt: attempt,
      status: :requested,
      metadata: normalize_map(Keyword.get(opts, :metadata, %{})),
      started_at: now
    }
  end

  @doc "Marks a publication as published and stores the result payload."
  @spec succeed(t(), map()) :: t()
  def succeed(%__MODULE__{} = publication, result) when is_map(result) do
    publication
    |> Map.put(:status, :published)
    |> Map.put(:result, result)
    |> Map.put(:external_ref, Map.get(result, :external_ref) || Map.get(result, "external_ref"))
    |> Map.put(:finished_at, now())
  end

  @doc "Marks a publication as failed and stores the error payload."
  @spec fail(t(), term(), keyword()) :: t()
  def fail(%__MODULE__{} = publication, error, opts \\ []) do
    publication
    |> Map.put(:status, :failed)
    |> Map.put(:error, normalize_error(error))
    |> Map.put(:result, normalize_map(Keyword.get(opts, :result, %{})))
    |> Map.put(:finished_at, now())
  end

  @doc "Valid built-in destination ids."
  @spec valid_destinations() :: [destination()]
  def valid_destinations, do: @valid_destinations

  @doc "Valid publication statuses."
  @spec valid_statuses() :: [status()]
  def valid_statuses, do: @valid_statuses

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_), do: %{}

  defp normalize_error(error) when is_binary(error), do: error
  defp normalize_error(%{message: message}) when is_binary(message), do: message
  defp normalize_error(error), do: inspect(error)
end
