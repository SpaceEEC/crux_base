defmodule Crux.Base do
  @moduledoc """
    TODO: Write me
  """

  use Supervisor

  alias Crux.Gateway.Connection.Producer

  @type options ::
          %{
            required(:gateway) => Crux.Gateway.gateway(),
            required(:cache_provider) => module()
          }
          | [{:gateway, Crux.Gateway.gateway()}]

  @spec start_link(opts :: options() | {options(), GenServer.options()}) :: Supervisor.on_start()
  def start_link({options, gen_opts}) do
    Supervisor.start_link(__MODULE__, options, gen_opts)
  end

  def start_link(options) do
    start_link({options, []})
  end

  def init(options) when is_list(options), do: options |> Map.new() |> init()

  def init(%{gateway: gateway, cache_provider: cache_provider}) do
    children =
      for {shard_id, _producer} <- Producer.producers(gateway) do
        [
          Supervisor.child_spec({Crux.Base.Consumer, {shard_id, gateway, cache_provider, self()}},
            id: {:consumer, shard_id}
          ),
          Supervisor.child_spec(
            {Crux.Base.Producer, shard_id},
            id: {:producer, shard_id}
          )
        ]
      end
      |> Enum.flat_map(& &1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  @spec consumers(base :: Supervisor.name()) :: %{required(pos_integer()) => pid()}
  def consumers(base) do
    base
    |> Supervisor.which_children()
    |> Enum.flat_map(fn
      {{:consumer, id}, pid, _type, _modules} ->
        [{id, pid}]

      _ ->
        []
    end)
    |> Map.new()
  end

  @doc """
    Computes a map of all producers keyed by shard_id.
  """
  @spec producers(base :: Supervisor.name()) :: %{required(pos_integer()) => pid()}
  def producers(base) do
    base
    |> Supervisor.which_children()
    |> Enum.flat_map(fn
      {{:producer, id}, pid, _type, _modules} ->
        [{id, pid}]

      _ ->
        []
    end)
    |> Map.new()
  end
end
