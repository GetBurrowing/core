defmodule Platform.Artifacts.Store do
  @moduledoc """
  ETS-backed artifact and publication store.

  The store keeps artifact records and publication history in-process so the
  Tasks/Execution MVP can expose deterministic publication state without adding
  a database migration to every early iteration. Writes are serialized through
  the GenServer; reads use public ETS tables for cheap listing.
  """

  use GenServer

  alias Platform.Artifacts.{Artifact, Publication}

  @artifact_table :platform_artifact_records
  @publication_table :platform_artifact_publications

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put_artifact(Artifact.t()) :: {:ok, Artifact.t()} | {:error, term()}
  def put_artifact(%Artifact{} = artifact) do
    GenServer.call(__MODULE__, {:put_artifact, artifact})
  end

  @spec get_artifact(String.t()) :: {:ok, Artifact.t()} | {:error, :not_found}
  def get_artifact(id) when is_binary(id) do
    case :ets.lookup(@artifact_table, id) do
      [{^id, artifact}] -> {:ok, artifact}
      [] -> {:error, :not_found}
    end
  end

  @spec list_artifacts(map()) :: [Artifact.t()]
  def list_artifacts(filters \\ %{}) when is_map(filters) do
    @artifact_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, artifact} -> artifact end)
    |> Enum.filter(&match_artifact?(&1, filters))
    |> Enum.sort_by(&{&1.task_id, &1.inserted_at || DateTime.from_unix!(0)})
  end

  @spec begin_publication(String.t(), Publication.destination(), keyword()) ::
          {:ok, Publication.t()} | {:error, term()}
  def begin_publication(artifact_id, destination, opts \\ []) do
    GenServer.call(__MODULE__, {:begin_publication, artifact_id, destination, opts})
  end

  @spec finish_publication(Publication.t()) :: {:ok, Publication.t()}
  def finish_publication(%Publication{} = publication) do
    GenServer.call(__MODULE__, {:finish_publication, publication})
  end

  @spec list_publications(String.t()) :: [Publication.t()]
  def list_publications(artifact_id) when is_binary(artifact_id) do
    @publication_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, publication} -> publication end)
    |> Enum.filter(&(&1.artifact_id == artifact_id))
    |> Enum.sort_by(& &1.attempt)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    artifact_table =
      :ets.new(@artifact_table, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    publication_table =
      :ets.new(@publication_table, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{artifact_table: artifact_table, publication_table: publication_table}}
  end

  @impl true
  def handle_call({:put_artifact, %Artifact{} = artifact}, _from, state) do
    case :ets.lookup(@artifact_table, artifact.id) do
      [] ->
        :ets.insert(@artifact_table, {artifact.id, artifact})
        {:reply, {:ok, artifact}, state}

      [_existing] ->
        {:reply, {:error, :already_exists}, state}
    end
  end

  def handle_call({:begin_publication, artifact_id, destination, opts}, _from, state) do
    with {:ok, _artifact} <- get_artifact(artifact_id),
         true <- destination in Publication.valid_destinations() do
      attempt = next_attempt_number(artifact_id)
      publication = Publication.begin(artifact_id, destination, attempt, opts)
      :ets.insert(@publication_table, {publication.id, publication})
      {:reply, {:ok, publication}, state}
    else
      {:error, _} = error -> {:reply, error, state}
      false -> {:reply, {:error, {:invalid_destination, destination}}, state}
    end
  end

  def handle_call({:finish_publication, %Publication{} = publication}, _from, state) do
    :ets.insert(@publication_table, {publication.id, publication})
    {:reply, {:ok, publication}, state}
  end

  defp next_attempt_number(artifact_id) do
    list_publications(artifact_id)
    |> Enum.map(& &1.attempt)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp match_artifact?(%Artifact{} = artifact, filters) do
    Enum.all?(filters, fn
      {:task_id, value} -> artifact.task_id == value
      {:run_id, value} -> artifact.run_id == value
      {:project_id, value} -> artifact.project_id == value
      {:epic_id, value} -> artifact.epic_id == value
      {:kind, value} -> artifact.kind == value
      {:source, value} -> artifact.source == value
      {_key, nil} -> true
      {_key, _value} -> true
    end)
  end
end
