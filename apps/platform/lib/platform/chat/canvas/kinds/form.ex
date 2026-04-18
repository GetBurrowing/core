defmodule Platform.Chat.Canvas.Kinds.Form do
  @moduledoc """
  Form with inline fields. Fields are declared in `props.fields`; children are
  not used. Submission emits a `submitted` event on the canvas topic with the
  collected values — it does NOT mutate the document. Agents and other
  subscribers decide how to respond.
  """

  use Platform.Chat.Canvas.Kind

  def children, do: :none

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["fields"],
      "properties" => %{
        "title" => %{"type" => "string"},
        "submit_label" => %{"type" => "string"},
        "fields" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["name", "type"],
            "properties" => %{
              "name" => %{"type" => "string"},
              "label" => %{"type" => "string"},
              "type" => %{
                "type" => "string",
                "enum" => ["text", "textarea", "number", "email", "url"]
              },
              "required" => %{"type" => "boolean"},
              "placeholder" => %{"type" => "string"},
              "default" => %{}
            }
          }
        },
        "class_overrides" => %{"type" => "string"}
      }
    }
  end

  def events do
    [
      %{
        "name" => "submitted",
        "payload_schema" => %{
          "type" => "object",
          "properties" => %{
            "node_id" => %{"type" => "string"},
            "values" => %{"type" => "object"}
          }
        }
      }
    ]
  end

  attr :node, :map, required: true

  def render(assigns) do
    props = assigns.node["props"] || %{}
    fields = List.wrap(props["fields"])

    assigns =
      assigns
      |> assign(:props, props)
      |> assign(:fields, fields)
      |> assign(:node_id, assigns.node["id"])

    ~H"""
    <form
      class={[
        "rounded-xl border border-base-300 bg-base-100 p-4 flex flex-col gap-3",
        @props["class_overrides"]
      ]}
      phx-submit="canvas_form_submit"
      phx-value-node-id={@node_id}
    >
      <p
        :if={@props["title"]}
        class="text-sm font-semibold text-base-content"
      >
        {@props["title"]}
      </p>
      <label :for={field <- @fields} class="flex flex-col gap-1">
        <span class="text-xs text-base-content/60">
          {field["label"] || field["name"]}
        </span>
        <%= case field["type"] do %>
          <% "textarea" -> %>
            <textarea
              name={"form[#{field["name"]}]"}
              placeholder={field["placeholder"] || ""}
              required={field["required"] == true}
              class="textarea textarea-bordered text-sm"
            >{field["default"] || ""}</textarea>
          <% _ -> %>
            <input
              type={field["type"] || "text"}
              name={"form[#{field["name"]}]"}
              placeholder={field["placeholder"] || ""}
              required={field["required"] == true}
              value={field["default"] || ""}
              class="input input-bordered input-sm text-sm"
            />
        <% end %>
      </label>
      <div class="flex justify-end">
        <button type="submit" class="btn btn-primary btn-sm">
          {@props["submit_label"] || "Submit"}
        </button>
      </div>
    </form>
    """
  end
end
