defmodule Crux.Base.Producer do
  @moduledoc false

  @behaviour GenStage
  use GenStage

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_shard_id) do
    GenStage.start_link(__MODULE__, nil)
  end

  @doc false
  @spec dispatch(Crux.Base.Processor.event()) :: :ok
  def dispatch({type, data, shard_id, base}) do
    pid = base |> Crux.Base.producers() |> Map.fetch!(shard_id)
    GenStage.cast(pid, {:dispatch, {type, data, shard_id}})
  end

  # Queue
  # rear - tail (in)
  # elements
  # elements
  # more elements
  # front - head (out)

  @doc false
  @impl true
  def init(_state) do
    {:producer, {:queue.new(), 0}, dispatcher: GenStage.BroadcastDispatcher}
  end

  @doc false
  @impl true
  def handle_cast({:dispatch, event}, {queue, demand}) do
    event
    |> :queue.in(queue)
    |> dispatch_events(demand, [])
  end

  @doc false
  @impl true
  def handle_demand(incoming_demand, {queue, demand}) do
    dispatch_events(queue, incoming_demand + demand, [])
  end

  defp dispatch_events(queue, demand, events) do
    with d when d > 0 <- demand,
         {{:value, event}, queue} <- :queue.out(queue) do
      dispatch_events(queue, demand - 1, [event | events])
    else
      _ ->
        {:noreply, Enum.reverse(events), {queue, demand}}
    end
  end
end
