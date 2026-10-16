defmodule Platform.Access.AgentTools do
  @moduledoc "Agent-facing access inspection and proposals; this module has no apply capability."
  import Ecto.Query
  alias Platform.Access
  alias Platform.Access.{Effective, Impact, Proposals, Scope, ViewAs}
  alias Platform.{Chat, Federation, Repo}

  def execute(tool, args, context) do
    runtime = Federation.get_runtime_by_runtime_id(context[:runtime_id])
    if runtime, do: dispatch(tool, args, runtime), else: error(:not_found)
  end

  defp dispatch("access_explain", args, runtime) do
    scope = Scope.for_runtime(runtime)

    with {:ok, target} <- target(args["target"]),
         {:ok, resource} <- resource(args["resource"]),
         permission = args["permission"] || read_permission(elem(resource, 0)),
         true <- Access.can?(scope, permission, resource) || {:error, :not_found},
         {:ok, view} <- ViewAs.compute(scope, target),
         {:ok, lines} <- Effective.lines(scope, target) do
      visible =
        case resource do
          {:project, id} -> Enum.any?(view.resources.projects, &(&1.id == id))
          {:space, id} -> Enum.any?(view.resources.channels, &(&1.id == id))
          _ -> Access.can?(view.scope, permission, resource)
        end

      {:ok,
       %{
         allowed: Access.can?(view.scope, permission, resource),
         sources:
           Enum.filter(lines, &(&1.permission == permission and &1.where.id == elem(resource, 1))),
         in_view_as: visible
       }}
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("access_propose", args, runtime) do
    with {:ok, options} <- options(args["options"]),
         :ok <- authorize_options(options, runtime) do
      create_card(runtime, args["space_id"], %{options: options})
    else
      {:error, reason} -> error(reason)
    end
  end

  defp dispatch("access_apply", args, runtime) do
    case Proposals.status(args["proposal_id"], runtime) do
      {:ok, row} ->
        {:ok,
         %{
           proposal_id: row.id,
           state: if(row.state == "proposed", do: "awaiting_human_approval", else: row.state),
           change_id: row.change_id,
           approved_by: row.approved_by_user_id,
           approved_at: row.approved_at,
           view_url: url(row)
         }}

      {:error, reason} ->
        error(reason)
    end
  end

  defp dispatch("access_undo", args, runtime) do
    case Impact.diff(Scope.for_runtime(runtime), args["change_id"]) do
      {:ok, _} ->
        create_card(runtime, args["space_id"], %{
          kind: "undo",
          undoes_change_id: args["change_id"]
        })

      {:error, reason} ->
        error(reason)
    end
  end

  defp dispatch(_, _, _), do: error(:not_found)

  defp create_card(runtime, space_id, attrs) do
    with true <- Platform.UUID.valid?(space_id) || {:error, :not_found},
         %Chat.Participant{} = participant <-
           Repo.one(
             from(p in Chat.Participant,
               where:
                 p.space_id == ^space_id and p.participant_type == "agent" and
                   p.participant_id == ^runtime.agent_id
             )
           ) || {:error, :not_found},
         {:ok, canvas, _message} <-
           Chat.create_canvas_with_message(space_id, participant.id, %{title: "Access change"}),
         {:ok, row} <-
           Proposals.propose(
             runtime,
             Map.merge(attrs, %{canvas_id: canvas.id, space_id: space_id})
           ),
         {:ok, row} <- Proposals.render_card(row) do
      option = hd(row.options)

      {:ok,
       %{
         proposal_id: row.id,
         canvas_id: row.canvas_id,
         view_url: url(row),
         count: option["impact"]["count"],
         conflicts: option["impact"]["conflicts"]
       }}
    else
      {:error, reason} -> error(reason)
    end
  end

  defp authorize_options(options, runtime) do
    Enum.reduce_while(options, :ok, fn option, _ ->
      case Impact.diff(Scope.for_runtime(runtime), option.ops) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp options(options) when is_list(options) and length(options) in 1..3 do
    try do
      parsed =
        Enum.with_index(options, fn option, index ->
          ops = Proposals.decode_ops(option["ops"])
          %{key: "option-#{index + 1}", label: "Access change", ops: ops}
        end)

      {:ok, parsed}
    rescue
      _ -> {:error, :invalid_options}
    end
  end

  defp options(_), do: {:error, :invalid_options}
  defp target(%{"type" => "user", "id" => id}), do: {:ok, {:user, id}}
  defp target(%{"type" => "agent", "id" => id}), do: {:ok, {:agent, id}}

  defp target(%{"type" => "role", "org_id" => org_id, "id" => key})
       when key in ~w(admin member guest), do: {:ok, {:role, org_id, key}}

  defp target(%{"type" => "role", "org_id" => org_id, "key" => key})
       when key in ~w(admin member guest), do: {:ok, {:role, org_id, key}}

  defp target(_), do: {:error, :not_found}

  defp resource(%{"type" => type, "id" => id})
       when type in ~w(project space canvas memory_node) do
    schema =
      case type do
        "project" -> Platform.Tasks.Project
        "space" -> Chat.Space
        "canvas" -> Chat.Canvas
        "memory_node" -> Platform.Org.Wiki.Node
      end

    if Platform.UUID.valid?(id) and Repo.get(schema, id),
      do: {:ok, {String.to_existing_atom(type), id}},
      else: {:error, :not_found}
  end

  defp resource(_), do: {:error, :not_found}
  defp read_permission(:project), do: "tasks.read"
  defp read_permission(:space), do: "chat.read"
  defp read_permission(:canvas), do: "canvas.read"
  defp read_permission(:memory_node), do: "memory.read"
  defp url(row), do: "/chat/#{row.space_id}?canvas=#{row.canvas_id}"
  defp error(reason), do: {:error, %{code: "access_refused", message: inspect(reason)}}
end
