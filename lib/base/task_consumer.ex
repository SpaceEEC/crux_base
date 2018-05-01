defmodule Crux.Base.TaskConsumer do
  @moduledoc """
    Provides a `__using__` macro to inject two functions to simplify consuming of gateway events.

    A somewhat example of this:

    A Supervisor, like `Crux.Base.ConsumerSupervisor`, and
    ```ex
  defmodule Bot.Consumer do
    use Crux.Base.TaskConsumer

    def handle_event({:MESSAGE_CREATE, message, _shard_id}) do
      IO.inspect(message)
    end

    def handle_event(_event), do: nil
  end
    ```
  """

  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour Crux.Base.TaskConsumer

      def start_link(event) do
        Task.start_link(fn -> handle_event(event) end)
      end

      def child_spec(_args) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, []},
          restart: :transient
        }
      end

      defoverridable child_spec: 1, start_link: 1
    end
  end

  @typedoc """
    All available element types.
  """
  @type event :: Crux.Base.Consumer.event()

  @doc """
    Will handle events.

    Be sure to have one "catch all" clause to not crash your consumer when you receive an event you didn't handle.
  """
  @callback handle_event(event :: event()) :: any()
end
