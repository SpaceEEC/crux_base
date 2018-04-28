defmodule Crux.Base.Application do
  @moduledoc """
    Crux "Base" module providing an example implementation of `Crux.Gateway`, `Crux.Rest`, and `Crux.Cache` while using `Crux.Structs`.

    You can set as environment for `:crux_base` a `token`.
    If the token is provided it will be forwarded to both `Crux.Gateway` and `Crux.Rest`.
    Also this will fetch and put the gateway `:url` and recommended `:shard_count` if not already specified.
  """

  use Application

  alias Crux.{Rest, Gateway, Structs}

  @registry Crux.Base.Registry

  def start(_type, _args) do
    Application.put_env(:crux_gateway, :dispatcher, GenStage.BroadcastDispatcher)
    Application.put_env(:crux_base, :dispatcher, GenStage.BroadcastDispatcher)

    with {:ok, token} <- Application.fetch_env(:crux_base, :token) do
      Application.put_env(:crux_gateway, :token, token)
      Application.put_env(:crux_rest, :token, token)
    end

    {:ok, res} = Rest.gateway_bot()
    %{url: url, shards: shard_count} = Structs.Util.atomify(res)

    with :error <- Application.fetch_env(:crux_gateway, :url) do
      Application.put_env(:crux_gateway, :url, url)
    end

    with :error <- Application.fetch_env(:crux_gateway, :shard_count) do
      Application.put_env(:crux_gateway, :shard_count, shard_count)
    end

    Gateway.start()

    children =
      [
        [{Registry, keys: :unique, name: @registry}]
        | for {shard_id, producer} <- Gateway.Connection.Producer.producers() do
            [
              Supervisor.child_spec(
                {Crux.Base.Consumer, {shard_id, producer}},
                id: "consumer_#{shard_id}"
              ),
              Supervisor.child_spec(
                {Crux.Base.Producer, shard_id},
                id: "producer_#{shard_id}"
              )
            ]
          end
      ]
      |> Enum.flat_map(fn element -> element end)

    Supervisor.start_link(children, strategy: :one_for_one, name: Crux.Base.Supervisor)
  end

  def producers() do
    Application.ensure_started(:crux_base)

    Application.fetch_env!(:crux_gateway, :shards)
    |> Map.new(fn shard_id ->
      pid =
        with [{pid, _other}] when is_pid(pid) <- Registry.lookup(@registry, shard_id),
             true <- Process.alive?(pid) do
          pid
        else
          _ ->
            :not_found
        end

      {shard_id, pid}
    end)
  end
end
