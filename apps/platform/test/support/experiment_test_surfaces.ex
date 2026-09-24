defmodule Platform.Experiments.TestSurfaces do
  @moduledoc """
  Non-prompt surfaces for tests (task 01a0d415 stage 2). The real non-prompt
  surfaces ship in stage 4; until then the guardrail, start and promotion
  paths for "any surface other than dispatch.prompt" need something to run
  against.

  Registered only for the duration of a test, through the
  `:experiments_extra_surfaces` app-env seam `Platform.Experiments.Surfaces.list/0`
  reads. `register/0` is for `async: false` tests only (it writes app env).
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "Registers both test surfaces until the calling test exits."
  def register do
    previous = Application.get_env(:platform, :experiments_extra_surfaces)

    Application.put_env(:platform, :experiments_extra_surfaces, [
      __MODULE__.Budget,
      __MODULE__.MailGenerator
    ])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:platform, :experiments_extra_surfaces, previous),
        else: Application.delete_env(:platform, :experiments_extra_surfaces)
    end)

    :ok
  end

  defmodule Budget do
    @moduledoc "A `planner.stage_budget`-shaped test surface: `%{\"max_stages\" => 1..10}`, control `%{}`."
    @behaviour Platform.Experiments.Surface

    @impl true
    def key, do: "test.budget"
    @impl true
    def subject_type, do: "task"
    @impl true
    def path, do: :dispatch
    @impl true
    def payload_schema, do: %{"type" => "object", "properties" => %{"max_stages" => %{}}}

    @impl true
    def validate_payload(%{"max_stages" => n}) when is_integer(n) and n in 1..10,
      do: {:ok, %{"max_stages" => n}}

    def validate_payload(payload) when payload == %{}, do: {:ok, %{}}
    def validate_payload(_payload), do: {:error, ["max_stages must be an integer in 1..10"]}

    @impl true
    def control_payload(_target, _opts), do: {:ok, %{}}
  end

  defmodule MailGenerator do
    @moduledoc "A `mail.*` test surface (draft path), for the mail promotion refusal."
    @behaviour Platform.Experiments.Surface

    @impl true
    def key, do: "mail.test.generator"
    @impl true
    def subject_type, do: "task"
    @impl true
    def path, do: :draft
    @impl true
    def payload_schema, do: %{"type" => "object", "properties" => %{"generator" => %{}}}

    @impl true
    def validate_payload(%{"generator" => g}) when is_binary(g) and g != "",
      do: {:ok, %{"generator" => g}}

    def validate_payload(_payload), do: {:error, ["generator is required"]}

    @impl true
    def control_payload(_target, _opts), do: {:ok, %{"generator" => "default"}}
  end
end
