defmodule Platform.Artifacts do
  @moduledoc """
  Public API for the artifact + destination substrate.

  This domain records produced artifacts independently from execution control,
  and then routes publication through destination modules. The split is
  deliberate: runners make artifacts, destinations publish them.
  """

  alias Platform.Artifacts.{Artifact, Destinations, Publication, Store}
  alias Platform.Context
  alias Platform.Execution

  @doc "Returns the destination ids supported by the shared publish contract."
  @spec supported_destinations() :: [Publication.destination()]
  def supported_destinations, do: Publication.valid_destinations()

  @doc "Registers an artifact record and, for run-scoped artifacts, mirrors a ref into context."
  @spec register_artifact(map() | keyword()) :: {:ok, Artifact.t()} | {:error, term()}
  def register_artifact(attrs) do
    with {:ok, artifact} <- Artifact.new(attrs),
         {:ok, artifact} <- Store.put_artifact(artifact) do
      artifact = hydrate_artifact(artifact)
      :ok = sync_context_ref(artifact)
      broadcast(artifact, :artifact_registered)
      {:ok, artifact}
    end
  end

  @doc "Registers an execution-scoped artifact for the given run."
  @spec register_execution_artifact(String.t(), map() | keyword()) ::
          {:ok, Artifact.t()} | {:error, term()}
  def register_execution_artifact(run_id, attrs) do
    with {:ok, run} <- Execution.get_run(run_id) do
      merged_attrs =
        attrs
        |> Enum.into(%{})
        |> Map.put_new(:project_id, run.project_id)
        |> Map.put_new(:epic_id, run.epic_id)
        |> Map.put_new(:task_id, run.task_id)
        |> Map.put_new(:run_id, run.id)
        |> Map.put_new(:source, :execution)

      register_artifact(merged_attrs)
    end
  end

  @doc "Fetches a single hydrated artifact."
  @spec get_artifact(String.t()) :: {:ok, Artifact.t()} | {:error, :not_found}
  def get_artifact(id) when is_binary(id) do
    with {:ok, artifact} <- Store.get_artifact(id) do
      {:ok, hydrate_artifact(artifact)}
    end
  end

  @doc "Lists hydrated artifacts using simple equality filters."
  @spec list_artifacts(keyword() | map()) :: [Artifact.t()]
  def list_artifacts(filters \\ %{}) do
    filters
    |> Enum.into(%{})
    |> Store.list_artifacts()
    |> Enum.map(&hydrate_artifact/1)
  end

  @doc "Lists publication attempts for an artifact, oldest first."
  @spec list_publications(String.t()) :: [Publication.t()]
  def list_publications(artifact_id), do: Store.list_publications(artifact_id)

  @doc "Publishes an artifact through a destination id or destination module."
  @spec publish_artifact(String.t() | Artifact.t(), atom() | module(), keyword()) ::
          {:ok, Artifact.t(), Publication.t()} | {:error, term(), Publication.t() | nil}
  def publish_artifact(artifact_or_id, destination, opts \\ []) do
    with {:ok, artifact} <- fetch_artifact(artifact_or_id),
         {:ok, destination_module, destination_id} <- resolve_destination(destination, opts),
         {:ok, reserved} <-
           Store.begin_publication(artifact.id, destination_id,
             metadata: publication_metadata(opts)
           ) do
      result = destination_module.publish(artifact, opts)

      case result do
        {:ok, publish_result} when is_map(publish_result) ->
          publication = Publication.succeed(reserved, publish_result)
          {:ok, publication} = Store.finish_publication(publication)
          artifact = refresh_and_broadcast(artifact.id, :artifact_published)
          {:ok, artifact, publication}

        {:error, reason} ->
          publication = Publication.fail(reserved, reason)
          {:ok, publication} = Store.finish_publication(publication)
          _artifact = refresh_and_broadcast(artifact.id, :artifact_publication_failed)
          {:error, reason, publication}

        other ->
          publication = Publication.fail(reserved, {:invalid_destination_result, other})
          {:ok, publication} = Store.finish_publication(publication)
          _artifact = refresh_and_broadcast(artifact.id, :artifact_publication_failed)
          {:error, {:invalid_destination_result, other}, publication}
      end
    end
  end

  @doc "Returns the PubSub topic for a task's artifact stream."
  @spec task_topic(String.t()) :: String.t()
  def task_topic(task_id), do: "artifacts:task:#{task_id}"

  @doc "Returns the PubSub topic for a specific artifact."
  @spec artifact_topic(String.t()) :: String.t()
  def artifact_topic(artifact_id), do: "artifacts:artifact:#{artifact_id}"

  @doc "Subscribe the caller to task-scoped artifact events."
  @spec subscribe_task(String.t()) :: :ok | {:error, term()}
  def subscribe_task(task_id), do: Phoenix.PubSub.subscribe(Platform.PubSub, task_topic(task_id))

  @doc "Subscribe the caller to artifact-scoped events."
  @spec subscribe_artifact(String.t()) :: :ok | {:error, term()}
  def subscribe_artifact(artifact_id),
    do: Phoenix.PubSub.subscribe(Platform.PubSub, artifact_topic(artifact_id))

  defp fetch_artifact(%Artifact{} = artifact), do: {:ok, hydrate_artifact(artifact)}
  defp fetch_artifact(id) when is_binary(id), do: get_artifact(id)

  defp resolve_destination(destination, opts) when is_atom(destination) do
    custom = Keyword.get(opts, :destinations, %{})

    custom_module = if is_map(custom), do: Map.get(custom, destination)

    cond do
      is_destination_module?(custom_module) ->
        {:ok, custom_module, destination}

      is_destination_module?(destination) ->
        {:ok, destination, destination.id()}

      true ->
        with {:ok, module} <- Destinations.fetch(destination) do
          {:ok, module, destination}
        end
    end
  end

  defp resolve_destination(module, _opts) when is_atom(module) do
    if is_destination_module?(module) do
      {:ok, module, module.id()}
    else
      {:error, :unknown_destination}
    end
  end

  defp is_destination_module?(module) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :id, 0) and
      function_exported?(module, :publish, 2)
  end

  defp is_destination_module?(_), do: false

  defp hydrate_artifact(%Artifact{} = artifact) do
    artifact
    |> Artifact.with_publications(Store.list_publications(artifact.id))
  end

  defp publication_metadata(opts) do
    opts
    |> Keyword.get(:publication_metadata, %{})
    |> case do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp refresh_and_broadcast(artifact_id, event_name) do
    {:ok, artifact} = get_artifact(artifact_id)
    :ok = sync_context_ref(artifact)
    broadcast(artifact, event_name)
    artifact
  end

  defp broadcast(%Artifact{} = artifact, event_name) do
    event = {event_name, artifact}
    Phoenix.PubSub.broadcast(Platform.PubSub, task_topic(artifact.task_id), event)
    Phoenix.PubSub.broadcast(Platform.PubSub, artifact_topic(artifact.id), event)
  end

  defp sync_context_ref(%Artifact{run_id: nil}), do: :ok

  defp sync_context_ref(%Artifact{} = artifact) do
    scope = %{
      project_id: artifact.project_id,
      epic_id: artifact.epic_id,
      task_id: artifact.task_id,
      run_id: artifact.run_id
    }

    with {:ok, _version} <-
           Context.put_item(scope, "artifact:#{artifact.id}", Artifact.to_ref(artifact),
             kind: :artifact_ref,
             meta: %{artifact_id: artifact.id}
           ) do
      :ok
    else
      _ -> :ok
    end
  end
end
