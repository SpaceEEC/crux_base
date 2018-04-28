defmodule Crux.Base.TaskConsumer do
  defmacro __using__(_opts) do
    quote location: :keep do
      def handle_event(_type, _data, _shard_id), do: nil

      def start_link({type, data, shard_id}) do
        Task.start_link(fn -> handle_event(type, data, shard_id) end)
      end

      def child_spec(_args) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, []},
          restart: :transient
        }
      end

      defoverridable handle_event: 3, child_spec: 1
    end
  end
end
