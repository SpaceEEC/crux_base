defmodule Crux.Base.ConsumerSupervisor do
  @moduledoc """
    Supervises a consumer, for example, a module using `Crux.Base.TaskConsumer`.

    A somewhat example of this:
    ```elixir
  defmodule Bot.Supervisor do
    def start_link(_), do: Supervisor.start_link(__MODULE__, %{}, name: __MODULE__)

    def init(_args) do
      children = [
        # other childrens...
        [{Crux.Base.ConsumerSupervisor, {Bot.Consumer, Bot.CruxBase}]
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end
  end
    ```
  """

  use Elixir.ConsumerSupervisor

  @doc false
  @spec start_link({module(), GenServer.server()}) :: Supervisor.on_start()
  def start_link({mod, _base} = args) when is_atom(mod) do
    ConsumerSupervisor.start_link(__MODULE__, args, [])
  end

  @impl true
  def init({children, base}) do
    producers = base |> Crux.Base.producers() |> Map.values()
    opts = [strategy: :one_for_one, subscribe_to: producers]

    ConsumerSupervisor.init([children], opts)
  end
end
