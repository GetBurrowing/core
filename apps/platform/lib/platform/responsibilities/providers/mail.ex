defmodule Platform.Responsibilities.Providers.Mail do
  @moduledoc """
  Provider shim for the `mail` feature. Reached only through the explicit
  `feature -> provider` registry in `Platform.Responsibilities.Providers`.

  Keys owned here, derived from each handler's own `key/0` (the
  `Providers.Janitor` pattern, so no second copy of a key can drift):

    * `mail.triage` → `Handlers.MailTriage` (task 01a1f426 stage 1)

  An unmapped or absent key returns exactly `{:error, :no_build_prompt}`, the
  one error the Router reads as "fall back to the template render".
  """
  @behaviour Platform.Responsibilities.Provider

  alias Platform.Responsibilities.Handlers.MailTriage
  alias Platform.Responsibilities.Responsibility

  @handlers [MailTriage]

  @doc "The handler modules this feature owns, in registration order."
  @spec handlers() :: [module()]
  def handlers, do: @handlers

  @impl true
  def register, do: Enum.flat_map(@handlers, & &1.register())

  @doc "The concrete handler for a responsibility or key; `nil` for keys this feature does not own."
  @spec handler_for(Responsibility.t() | %{key: String.t()} | String.t() | any()) ::
          module() | nil
  def handler_for(%Responsibility{key: key}), do: handler_for(key)
  def handler_for(%{key: key}), do: handler_for(key)
  def handler_for(key) when is_binary(key), do: Enum.find(@handlers, &(&1.key() == key))
  def handler_for(_), do: nil

  @impl true
  def gather_context(%Responsibility{} = responsibility, ctx) when is_map(ctx) do
    case handler_for(responsibility) do
      nil -> {:ok, %{}}
      handler -> handler.gather_context(responsibility, ctx)
    end
  end

  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  @impl true
  def build_prompt(context) when is_map(context) do
    case handler_for(Map.get(context, :__responsibility__)) do
      nil -> {:error, :no_build_prompt}
      handler -> handler.build_prompt(context)
    end
  end

  def build_prompt(_context), do: {:error, :no_build_prompt}

  @impl true
  def handle_output(responsibility, parsed), do: handle_output(responsibility, parsed, %{})

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed, trigger_meta)
      when is_map(trigger_meta) do
    case handler_for(responsibility) do
      nil -> :ok
      handler -> handler.handle_output(responsibility, parsed, trigger_meta)
    end
  end

  def handle_output(_responsibility, _parsed, _trigger_meta), do: :ok
end
