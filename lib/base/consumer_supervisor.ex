defmodule Crux.Base.ConsumerSupervisor do
  @moduledoc """
    Supervises a consumer, for example, a module using `Crux.Base.TaskConsumer`.
    
    A somewhat example of this:
    ```ex
  defmodule Bot.Supervisor do
    def start_link(_), do: Supervisor.start_link(__MODULE__, %{}, name: __MODULE__)

    def init(_args) do
      children = [
        # other childrens...
        {Crux.Base.ConsumerSupervisor, [Bot.Consumer]}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end
  end
    ```
  """

  use ConsumerSupervisor

  @doc false
  def start_link([mod] = args) when is_atom(mod) do
    ConsumerSupervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(children) do
    producers = Crux.Base.producers() |> Map.values()
    opts = [strategy: :one_for_one, subscribe_to: producers]

    ConsumerSupervisor.init(children, opts)
  end
end
