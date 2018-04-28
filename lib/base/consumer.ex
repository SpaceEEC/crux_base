defmodule Crux.Base.Consumer do
  @moduledoc """
    Handles consuming and processing of events received from the gateway.
    To consume those processed events subscribe with a consumer to a `Crux.Base.Producer`.
  """

  use GenStage

  alias Crux.Cache

  alias Crux.Structs
  alias Crux.Structs.{Channel, Emoji, Guild, Member, Message, Role, User, VoiceState}

  @registry Crux.Base.Registry

  @doc false
  def start_link({shard_id, target}) do
    name = {:via, Registry, {@registry, shard_id}}
    GenStage.start_link(__MODULE__, target, name: name)
  end

  @doc false
  def init(target) do
    {:producer_consumer, nil, dispatcher: GenStage.BroadcastDispatcher, subscribe_to: [target]}
  end

  @doc false
  def handle_events(events, _from, state) do
    events =
      for {type, data, shard_id} <- events do
        {type, handle_event(type, data, shard_id), shard_id}
      end
      |> Enum.filter(&elem(&1, 1))

    {:noreply, events, state}
  end

  # https://discordapp.com/developers/docs/topics/gateway#ready-ready-event-fields
  @doc false
  defp handle_event(:READY, data, _shard_id) do
    Map.update!(
      data,
      :guilds,
      &Enum.map(&1, fn guild ->
        Structs.create(guild, Guild)
        |> Cache.guild_cache().update()
      end)
    )

    data = Map.update!(data, :user, &Cache.user_cache().update/1)

    Cache.user_cache().me(data.user.id)

    data
  end

  # https://discordapp.com/developers/docs/topics/gateway#resumed
  defp handle_event(:RESUMED, data, _shard_id), do: data
  # https://discordapp.com/developers/docs/topics/gateway#channel-create
  defp handle_event(:CHANNEL_CREATE, data, _shard_id) do
    channel = Cache.channel_cache().update(data)

    with %{guild_id: guild_id} when is_integer(guild_id) <- channel,
         do: Cache.guild_cache().insert(channel)

    channel
  end

  # https://discordapp.com/developers/docs/topics/gateway#channel-update
  defp handle_event(:CHANNEL_UPDATE, data, _shard_id) do
    old = with {:ok, channel} <- Cache.channel_cache().fetch(data.id) do
      channel
    else
      _ ->
        nil
    end

    {old, Cache.channel_cache().update(data)}
  end

  # https://discordapp.com/developers/docs/topics/gateway#channel-delete
  defp handle_event(:CHANNEL_DELETE, data, _shard_id) do
    channel =
      with {:ok, channel} <- Cache.channel_cache().fetch(data.id) do
        channel
      else
        _ ->
          Structs.create(data, Channel)
      end

    Cache.channel_cache().delete(data.id)

    with %{guild_id: guild_id} when is_integer(guild_id) <- data,
         do: Cache.guild_cache().delete(channel)

    channel
  end

  # https://discordapp.com/developers/docs/topics/gateway#channel-pins-update
  defp handle_event(:CHANNEL_PINS_UPDATE, data, _shard_id) do
    case Cache.channel_cache().fetch(data.channel_id) do
      {:ok, channel} ->
        {channel, Map.get(data, :last_pin_timestamp)}

      _ ->
        nil
    end
  end

  # https://discordapp.com/developers/docs/topics/gateway#guild-create
  # https://discordapp.com/developers/docs/topics/gateway#guild-update
  defp handle_event(guild_event, data, _shard_id)
       when guild_event in [:GUILD_CREATE, :GUILD_UPDATE] do
    guild = Structs.create(data, Guild)

    if Map.has_key?(data, :members) do
      Enum.each(data.members, fn member -> Cache.user_cache().insert(member.user) end)
    end

    if Map.has_key?(data, :channels) do
      Enum.each(data.channels, fn channel ->
        channel
        |> Map.put(:guild_id, data.id)
        |> Cache.channel_cache().insert()
      end)
    end

    if Map.has_key?(data, :emojis) do
      Enum.each(data.emojis, &Cache.emoji_cache().insert/1)
    end

    if Map.has_key?(data, :presences) do
      Enum.each(data.presences, fn presence ->
        presence
        |> Map.put(:id, presence.user.id)
        |> Cache.presence_cache().insert()
      end)
    end

    case Cache.guild_cache().lookup(guild.id) do
      {:ok, _pid} when guild_event == :GUILD_CREATE ->
        # Guild was already known, see :READY, not emitting guild create
        Cache.guild_cache().insert(guild)

        nil

      {:ok, _pid} ->
        # must be GUILD_UPDATE
        {guild, Cache.guild_cache().update(guild)}

      :error ->
        Cache.Guild.Supervisor.start_child(guild)

        if guild_event == :GUILD_CREATE,
          do: guild,
          else: {nil, guild}
    end
  end

  # https://discordapp.com/developers/docs/topics/gateway#guild-delete
  defp handle_event(:GUILD_DELETE, data, shard_id) do
    guild =
      data
      |> Map.put(:shard_id, shard_id)
      |> Structs.create(Guild)

    if guild.unavailable do
      Cache.guild_cache().update(guild)
    else
      Cache.guild_cache().delete(guild.id, :remove)

      guild
    end
  end

  # https://discordapp.com/developers/docs/topics/gateway#guild-ban-add
  defp handle_event(:GUILD_BAN_ADD, data, _shard_id) do
    case Cache.guild_cache().fetch(data.guild_id) do
      {:ok, guild} ->
        user = Structs.create(data.user, User)
        Cache.guild_cache().delete(data.guild_id, user)

        {user, guild}

      _ ->
        nil
    end
  end

  # https://discordapp.com/developers/docs/topics/gateway#guild-ban-removed
  defp handle_event(:GUILD_BAN_REMOVE, data, _shard_id) do
    case Cache.guild_cache().fetch(data.guild_id) do
      {:ok, guild} ->
        user = Structs.create(data.user, User)

        {user, guild}

      _ ->
        nil
    end
  end

  # https://discordapp.com/developers/docs/topics/gateway#guild-emojis-update
  defp handle_event(:GUILD_EMOJIS_UPDATE, data, _shard_id) do
    old_emojis =
      with {:ok, %{emojis: emojis}} <- Cache.guild_cache().fetch(data.guild_id) do
        emojis
      else
        _->
          nil
      end

    emojis = Structs.create(data.emojis, Emoji)
    Cache.guild_cache().update({data.guild_id, {:emojis, emojis}})

    {old_emojis, emojis}
  end

  # https://discordapp.com/developers/docs/topics/gateway#guild-integrations-update
  defp handle_event(:GUILD_INTEGRATIONS_UPDATE, data, _shard_id), do: data

  # https://discordapp.com/developers/docs/topics/gateway#guild-member-add
  defp handle_event(:GUILD_MEMBER_ADD, data, _shard_id) do
    member = Structs.create(data, Member)

    Cache.guild_cache().update(member)
  end

  # https://discordapp.com/developers/docs/topics/gateway#guild-member-remove
  defp handle_event(:GUILD_MEMBER_REMOVE, data, _shard_id) do
    case Cache.guild_cache().fetch(data.guild_id) do
      {:ok, guild} ->
        user = Structs.create(data.user, User)
        Cache.guild_cache().delete(guild.id, user)

        {guild, user}

      _ ->
        nil
    end
  end

  # https://discordapp.com/developers/docs/topics/gateway#guild-member-update
  defp handle_event(:GUILD_MEMBER_UPDATE, data, _shard_id) do
    member = Structs.create(data, Member)

    Cache.guild_cache().update(member)
  end

  # https://discordapp.com/developers/docs/topics/gateway#guild-members-chunk
  defp handle_event(:GUILD_MEMBERS_CHUNK, data, _shard_id) do
    members = Structs.create(data.members, Member)

    Cache.guild_cache().update({data.guild_id, {:members, members}})
  end

  # https://discordapp.com/developers/docs/topics/gateway#guild-role-create
  defp handle_event(type, data, _shard_id) when type in [:GUILD_ROLE_CREATE, :GUILD_ROLE_UPDATE] do
    role =
      data.role
      |> Map.put(:guild_id, data.guild_id)
      |> Structs.create(Role)

    Cache.guild_cache().update(role)
  end

  # https://discordapp.com/developers/docs/topics/gateway#guild-role-delete
  defp handle_event(:GUILD_ROLE_DELETE, %{role_id: role_id, guild_id: guild_id}, _shard_id) do
    with {:ok, %{roles: %{^role_id => role}}} <- Cache.guild_cache().fetch(guild_id) do
      Cache.guild_cache().delete(guild_id, {:role, role_id})

      role
    else
      _->
        nil
    end
  end

  # https://discordapp.com/developers/docs/topics/gateway#message-create
  defp handle_event(:MESSAGE_CREATE, data, _shard_id) do
    unless Map.get(data, :webhook_id), do: Cache.user_cache().insert(data.author)
    Enum.each(data.mentions, &Cache.user_cache().insert/1)

    Structs.create(data, Message)
  end

  # https://discordapp.com/developers/docs/topics/gateway#message-update
  defp handle_event(:MESSAGE_UPDATE, data, _shard_id) do
    case data do
      %{author: _author} ->
        Structs.create(data, Message)

      # Embed update, only has channel_id, id, and embeds
      _ ->
        data
    end
  end

  # https://discordapp.com/developers/docs/topics/gateway#message-delete
  defp handle_event(:MESSAGE_DELETE, data, _shard_id) do
    case Cache.channel_cache().fetch(data.channel_id) do
      :error ->
        nil

      {:ok, channel} ->
        {data.id, channel}
    end
  end

  # https://discordapp.com/developers/docs/topics/gateway#message-delete-bulk
  defp handle_event(:MESSAGE_DELETE_BULK, data, _shard_id) do
    case Cache.channel_cache().fetch(data.channel_id) do
      :error ->
        nil

      {:ok, channel} ->
        {data.ids, channel}
    end
  end

  # https://discordapp.com/developers/docs/topics/gateway#message-reaction-add
  # https://discordapp.com/developers/docs/topics/gateway#message-reaction-remove
  defp handle_event(type, data, _shard_id)
       when type in [:MESSAGE_REACTION_ADD, :MESSAGE_REACTION_REMOVE] do
    emoji =
      case data.emoji.id do
        nil ->
          {:ok, data.emoji}

        id ->
          with :error <- Cache.emoji_cache().fetch(id),
               do: {:ok, Structs.create(data.emoji, Emoji)}
      end

    with {:ok, user} <- Cache.user_cache().fetch(data.user_id),
         {:ok, channel} <- Cache.channel_cache().fetch(data.channel_id),
         {:ok, emoji} <- emoji do
      {user, channel, data.message_id, emoji}
    else
      _ ->
        nil
    end
  end

  # https://discordapp.com/developers/docs/topics/gateway#message-reaction-remove-all
  defp handle_event(:MESSAGE_REACTION_REMOVE_ALL, data, _shard_id) do
    case Cache.channel_cache().fetch(data.channel_id) do
      {:ok, channel} ->
        {data.message_id, channel}

      _ ->
        nil
    end
  end

  # https://discordapp.com/developers/docs/topics/gateway#presence-update
  defp handle_event(:PRESENCE_UPDATE, data, _shard_id) do
    presence =
      data
      |> Map.put(:id, data.user.id)
      |> Cache.presence_cache().update()

    user =
      Cache.user_cache().update(data.user)
      |> Structs.create(User)

    with %{roles: roles, guild_id: guild_id} <- data,
         do: Cache.guild_cache().insert({guild_id, {user, roles}})

    presence
  end

  # https://discordapp.com/developers/docs/topics/gateway#typing-start
  defp handle_event(:TYPING_START, data, _shard_id) do
    with {:ok, channel} <- Cache.channel_cache().fetch(data.channel_id),
         {:ok, user} <- Cache.user_cache().fetch(data.user_id) do
      {channel, user, data.timestamp}
    else
      _ ->
        nil
    end
  end

  # https://discordapp.com/developers/docs/topics/gateway#user-update
  defp handle_event(:USER_UPDATE, data, _shard_id), do: Cache.user_cache().update(data)

  defp handle_event(:VOICE_STATE_UPDATE, data, _shard_id) do
    voice_state = Structs.create(data, VoiceState)

    Cache.guild_cache().update(voice_state)
  end

  # https://discordapp.com/developers/docs/topics/gateway#voice-server-update
  defp handle_event(:VOICE_SERVER_UPDATE, data, _shard_id), do: data

  # https://discordapp.com/developers/docs/topics/gateway#webhooks-update
  defp handle_event(:WEBHOOKS_UPDATE, data, _shard_id) do
    with {:ok, guild} <- Cache.guild_cache().fetch(data.guild_id),
         {:ok, channel} <- Cache.channel_cache().fetch(data.channel_id) do
      {guild, channel}
    else
      _ ->
        nil
    end
  end

  defp handle_event(type, data, shard_id) do
    require Logger

    Logger.warn(
      "[Crux][Base][Consumer] Unhandled type #{type} from shard #{shard_id}, with data #{
        inspect(data)
      }"
    )

    data
  end
end
