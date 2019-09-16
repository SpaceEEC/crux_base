defmodule Crux.Base do
  @moduledoc """
    TODO: Write me
  """

  use Supervisor

  alias Crux.Gateway.Connection.Producer

  @type options ::
          %{
            required(:gateway) => Crux.Gateway.gateway(),
            required(:cache_provider) => module(),
            optional(:consumer) => module(),
            optional(:producer) => module()
          }
          | [
              {:gateway, Crux.Gateway.gateway()}
              | {:cache_provider, module()}
              | {:consumer, module()}
              | {:producer, module()}
            ]

  @spec start_link(opts :: options() | {options(), GenServer.options()}) :: Supervisor.on_start()
  def start_link({options, gen_opts}) do
    Supervisor.start_link(__MODULE__, options, gen_opts)
  end

  def start_link(options) do
    start_link({options, []})
  end

  @impl true
  def init(options) when is_list(options), do: options |> Map.new() |> init()

  def init(%{gateway: gateway, cache_provider: cache_provider}) do
    consumer = Map.get(:consumer, Crux.Base.Consumers)
    producer = Map.get(:consumer, Crux.Base.Producer)

    consumer_opts = %{
      gateway: gateway,
      cache_provider: cache_provider,
      base: self()
      # shard_id
    }

    children =
      for {shard_id, _producer} <- Producer.producers(gateway) do
        [
          Supervisor.child_spec({consumer, %{consumer_opts | shard_id: shard_id}},
            id: {:consumer, shard_id}
          ),
          Supervisor.child_spec(
            {producer, shard_id},
            id: {:producer, shard_id}
          )
        ]
      end

    children
    |> Enum.flat_map(& &1)
    |> Supervisor.init(strategy: :one_for_one)
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
