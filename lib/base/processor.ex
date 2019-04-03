defmodule Crux.Base.Processor do
  @moduledoc """
    Module processing gateway packets into `t:event/0`s making necessary cache lookups / insertions.
  """

  use GenStage

  alias Crux.Structs

  alias Crux.Structs.{
    Channel,
    Emoji,
    Guild,
    Member,
    Message,
    Presence,
    Role,
    User,
    Util,
    VoiceState
  }

  @typedoc """
    The id of a shard.
  """
  @type shard_id :: non_neg_integer()

  @typedoc """
    A discord snowflake.
    See `t:Crux.Rest.Snowflake/0` for more information.
  """
  @type snowflake :: Crux.Rest.snowflake()

  @typedoc """
    The id of a guild.
  """
  @type guild_id :: snowflake()
  @typedoc """
    The id of a role.
  """
  @type role_id :: snowflake()

  @typedoc """
    The id of a channel.
  """
  @type channel_id :: snowflake()

  @typedoc """
    The id of a message.
  """
  @type message_id :: snowflake()

  @typedoc """
    The id of a user.
  """
  @type user_id :: snowflake()

  @typedoc """
    Union type of all available events.
  """
  @type event ::
          ready_event()
          | resumed_event()
          | channel_create_event()
          | channel_update_event()
          | channel_update_event()
          | channel_delete_event()
          | channel_pins_update_event()
          | guild_create_event()
          | guild_update_event()
          | guild_delete_event()
          | guild_ban_add_event()
          | guild_ban_remove_event()
          | guild_emojis_update_event()
          | guild_integrations_update_event()
          | guild_member_add_event()
          | guild_member_remove_event()
          | guild_member_update_event()
          | guild_members_chunk_event()
          | guild_role_create_event()
          | guild_role_update_event()
          | guild_role_delete_event()
          | message_create_event()
          | message_update_event()
          | message_delete_event()
          | message_delete_bulk_event()
          | message_reaction_add_event()
          | message_reaction_remove_event()
          | message_reaction_remove_all_event()
          | presence_update_event()
          | typing_start_event()
          | user_update_event()
          | voice_state_update_event()
          | voice_server_update_event()
          | webhooks_update_event()

  @typedoc """
    Emitted when a gateway connection completed the initial handshake with the gateway.
    The guilds are not yet sent, those are partial unavailable guilds!

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#ready).
  """
  @type ready_event ::
          {:READY,
           %{
             v: integer(),
             user: User.t(),
             # always empty for bots
             private_channels: [],
             guilds: [Guild.t()],
             session_id: String.t(),
             _trace: [String.t()]
           }, shard_id()}

  @doc """
    Processes the `type` (`t` value of a packet) along its `data` (`d` portion of a packet).
    This will do necessary transformation, cache lookups, and cache insertions.

    Returns an `t:event/0` or a list of them.
  """
  @spec process_event(
          type :: atom(),
          data :: term(),
          shard_id :: shard_id(),
          cache_provider :: term()
        ) :: event() | [event()]
  def process_event(:READY, data, _shard_id, cache_provider) do
    Map.update!(
      data,
      :guilds,
      &Enum.map(&1, fn guild ->
        guild
        |> Structs.create(Guild)
        |> cache_provider.guild_cache().update()
      end)
    )

    data = Map.update!(data, :user, &cache_provider.user_cache().update/1)

    cache_provider.user_cache().me(data.user.id)

    data
  end

  @typedoc """
    Emitted whenever a gateway connection resumed after unexpectedly disconnecting.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#resumed).
  """
  @type resumed_event :: {:RESUMED, %{_trace: [String.t()]}, shard_id()}

  def process_event(:RESUMED, data, _shard_id, _cache_provider), do: data

  @typedoc """
    Emitted whenever a channel was created.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#channel-create).
  """
  @type channel_create_event :: {:CHANNEL_CREATE, Channel.t(), shard_id()}

  def process_event(:CHANNEL_CREATE, data, _shard_id, cache_provider) do
    channel =
      data
      |> cache_provider.channel_cache().update()
      |> Structs.create(Channel)

    with %{guild_id: guild_id} when is_integer(guild_id) <- channel,
         do: cache_provider.guild_cache().insert(channel)

    channel
  end

  @typedoc """
    Emitted whenever a channel was updated.

    Emits nil if the channel was uncached previously.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#channel-update).
  """
  @type channel_update_event :: {:CHANNEL_UPDATE, {Channel.t() | nil, Channel.t()}, shard_id()}

  def process_event(:CHANNEL_UPDATE, data, _shard_id, cache_provider) do
    old =
      case cache_provider.channel_cache().fetch(data.id) do
        {:ok, channel} ->
          channel

        :error ->
          nil
      end

    {old, cache_provider.channel_cache().update(data)}
  end

  @typedoc """
    Emitted whenever a channel was deleted.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#channel-delete).
  """
  @type channel_delete_event :: {:CHANNEL_DELETE, Channel.t(), shard_id()}

  def process_event(:CHANNEL_DELETE, data, _shard_id, cache_provider) do
    channel = Structs.create(data, Channel)
    cache_provider.channel_cache().delete(data.id)

    with %{guild_id: guild_id} when is_integer(guild_id) <- data,
         do: cache_provider.guild_cache().delete(channel)

    channel
  end

  @typedoc """
    Emitted whenever a message was pinned or unpinned.

    Emits the channel id if the channel was uncached.

    > The second element of the tuple is the timestamp of when the last pinned message was pinned.
    > The timestamp will be the Unix Epoch if last pinned message was removed.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#channel-pins-update).
  """
  @type channel_pins_update_event ::
          {:CHANNEL_PINS_UPDATE, {Channel.t() | channel_id(), String.t()}, shard_id()}

  def process_event(
        :CHANNEL_PINS_UPDATE,
        %{channel_id: channel_id} = data,
        _shard_id,
        cache_provider
      ) do
    case cache_provider.channel_cache().fetch(channel_id) do
      {:ok, channel} ->
        {channel, Map.get(data, :last_pin_timestamp)}

      :error ->
        {channel_id, Map.get(data, :last_pin_timestamp)}
    end
  end

  @typedoc """
    Emitted whenever the client joined a guild.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-create).
  """
  @type guild_create_event :: {:GUILD_CREATE, Guild.t(), shard_id()}

  @typedoc """
    Emitted whenever a guild updated.

    Emits nil as guild before the update if it was uncached previously.

    Fore more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-update).
  """
  @type guild_update_event :: {:GUILD_UPDATE, {Guild.t() | nil, Guild.t()}, shard_id()}

  def process_event(guild_event, data, _shard_id, cache_provider)
      when guild_event in [:GUILD_CREATE, :GUILD_UPDATE] do
    guild = Structs.create(data, Guild)

    data
    |> Map.get(:members, [])
    |> Enum.each(fn member -> cache_provider.user_cache().insert(member.user) end)

    data
    |> Map.get(:channels, [])
    |> Enum.each(fn channel ->
      channel
      |> Map.put(:guild_id, data.id)
      |> cache_provider.channel_cache().insert()
    end)

    data
    |> Map.get(:emojis, [])
    |> Enum.each(&cache_provider.emoji_cache().insert/1)

    data
    |> Map.get(:presences, [])
    |> Enum.each(fn presence ->
      presence
      |> Map.put(:id, presence.user.id)
      |> cache_provider.presence_cache().insert()
    end)

    case cache_provider.guild_cache().fetch(guild.id) do
      {:ok, _guild} when guild_event == :GUILD_CREATE ->
        # Guild was already known, see :READY, not emitting guild create
        cache_provider.guild_cache().insert(guild)

        nil

      {:ok, _guild} ->
        # must be GUILD_UPDATE
        {guild, cache_provider.guild_cache().update(guild)}

      :error ->
        cache_provider.guild_cache().insert(guild)

        if guild_event == :GUILD_CREATE,
          do: guild,
          else: {nil, guild}
    end
  end

  @typedoc """
    Emitted whenever the client left a guild or a guild became unavailable.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-delete).
  """
  @type guild_delete_event :: {:GUILD_DELETE, Guild.t(), shard_id()}

  def process_event(:GUILD_DELETE, data, shard_id, cache_provider) do
    guild =
      data
      |> Map.put(:shard_id, shard_id)
      |> Structs.create(Guild)

    if guild.unavailable do
      cache_provider.guild_cache().update(guild)
    else
      cache_provider.guild_cache().delete(guild.id)

      guild
    end
  end

  @typedoc """
    Emitted whenever a user was banned from a guild.

    Emits a user if the member was not cached.
    Emits the guild id if the guild was not cached.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-ban-add).
  """
  @type guild_ban_add_event ::
          {:GUILD_BAN_ADD, {User.t() | Member.t(), Guild.t() | guild_id()}, shard_id()}

  def process_event(
        :GUILD_BAN_ADD,
        %{guild_id: guild_id, user: %{id: id} = user},
        _shard_id,
        cache_provider
      ) do
    case cache_provider.guild_cache().fetch(guild_id) do
      {:ok, %{members: %{^id => member}} = guild} ->
        {member, guild}

      {:ok, guild} ->
        {Structs.create(user, User), guild}

      :error ->
        {Structs.create(user, User), guild_id}
    end
  end

  @typedoc """
  Emitted whenever a user was unbanned from a guild.

  Emits the guild id if the guild was not cached.

  For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-ban-removed).
  """
  @type guild_ban_remove_event ::
          {:GUILD_BAN_REMOVE, {User.t(), Guild.t() | guild_id()}, shard_id()}

  def process_event(
        :GUILD_BAN_REMOVE,
        %{guild_id: guild_id, user: user},
        _shard_id,
        cache_provider
      ) do
    user = Structs.create(user, User)

    case cache_provider.guild_cache().fetch(guild_id) do
      {:ok, guild} ->
        {user, guild}

      :error ->
        {user, guild_id}
    end
  end

  @typedoc """
    Emitted whenever a guild's emojis updated.

    The first element is a list of the emojis before the update.
    The second element is al ist of the emojis after the update.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-emojis-update).
  """
  @type guild_emojis_update_event ::
          {:GUILD_EMOJIS_UPDATE, {[Emoji.t()], [Emoji.t()]}, shard_id()}

  def process_event(:GUILD_EMOJIS_UPDATE, data, _shard_id, cache_provider) do
    old_emojis =
      for {:ok, %{emojis: emojis}} <- [cache_provider.guild_cache().fetch(data.guild_id)],
          emoji_id <- emojis,
          {:ok, emoji} <- [cache_provider.emoji_cache().fetch(emoji_id)] do
        emoji
      end

    emojis = Structs.create(data.emojis, Emoji)
    cache_provider.guild_cache().update({data.guild_id, {:emojis, emojis}})

    {old_emojis, emojis}
  end

  @typedoc """
    Emitted whenever one of a guild's integration was updated.

    Emits the guild id if the guild was not cached.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-integrations-update).
  """
  @type guild_integrations_update_event ::
          {:GUILD_INTEGRATIONS_UPDATE, Guild.t() | guild_id(), shard_id()}

  def process_event(:GUILD_INTEGRATIONS_UPDATE, %{guild_id: guild_id}, _shard_id, cache_provider) do
    case cache_provider.guild_cache().fetch(guild_id) do
      {:ok, guild} ->
        guild

      :error ->
        guild_id
    end
  end

  @typedoc """
    Emitted whenever a user joined a guild.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-member-add).
  """
  @type guild_member_add_event :: {:GUILD_MEMBER_ADD, Member.t(), shard_id()}

  def process_event(:GUILD_MEMBER_ADD, data, _shard_id, cache_provider) do
    data
    |> Structs.create(Member)
    |> cache_provider.guild_cache().update()
  end

  @typedoc """
    Emitted whenever a user left a guild.
    This includes kicks and bans.

    Emits the user if the member was not cached.
    Emits the guild id if the guild was not cached.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-member-remove).
  """
  @type guild_member_remove_event ::
          {:GUILD_MEMBER_REMOVE, {User.t() | Member.t(), Guild.t() | guild_id()}, shard_id()}

  def process_event(
        :GUILD_MEMBER_REMOVE,
        %{guild_id: guild_id, user: %{id: id} = user},
        _shard_id,
        cache_provider
      ) do
    case cache_provider.guild_cache().fetch(guild_id) do
      {:ok, %{members: %{^id => member}} = guild} ->
        cache_provider.guild_cache().delete(member)
        {member, guild}

      {:ok, guild} ->
        {Structs.create(user, User), guild}

      :error ->
        {Structs.create(user, User), guild_id}
    end
  end

  @typedoc """
    Emitted whenever a guild member was updated.

    Emits nil as the member before the updated if it was uncached.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-member-update).
  """
  @type guild_member_update_event ::
          {:GUILD_MEMBER_UPDATE, {Member.t() | nil, Member.t()}, shard_id()}

  def process_event(:GUILD_MEMBER_UPDATE, data, _shard_id, cache_provider) do
    member = %{user: id} = Structs.create(data, Member)

    old_member =
      case cache_provider.guild_cache().fetch(member.guild_id) do
        {:ok, %{members: %{^id => old_member}}} ->
          old_member

        :error ->
          nil
      end

    {old_member, cache_provider.guild_cache().update(member)}
  end

  @typedoc """
    Emitted whenever a chunk of guild members was received.

    For more information see `Crux.Gateway.Command.request_guild_members/2` and [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-members-chunk).
  """
  @type guild_members_chunk_event :: {:GUILD_MEMBERS_CHUNK, [Member.t()], shard_id()}

  def process_event(:GUILD_MEMBERS_CHUNK, data, _shard_id, cache_provider) do
    members = Structs.create(data.members, Member)

    cache_provider.guild_cache().update({data.guild_id, {:members, members}})
  end

  @typedoc """
    Emitted whenever a role was created.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-role-create).
  """
  @type guild_role_create_event :: {:GUILD_ROLE_CREATE, Role.t(), shard_id()}

  def process_event(:GUILD_ROLE_CREATE, data, _shard_id, cache_provider) do
    role =
      data.role
      |> Map.put(:guild_id, data.guild_id)
      |> Structs.create(Role)

    cache_provider.guild_cache().update(role)
  end

  @typedoc """
    Emitted whenever a role was updated.

    Emits nil as the role before the update if it was uncached previously.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-role-update).
  """
  @type guild_role_update_event :: {:GUILD_ROLE_UPDATE, {Role.t() | nil, Role.t()}, shard_id()}

  def process_event(
        :GUILD_ROLE_UPDATE,
        %{guild_id: guild_id, role: %{id: id}} = data,
        shard_id,
        cache_provider
      ) do
    old_role =
      case cache_provider.guild_cache().fetch(guild_id) do
        {:ok, %{roles: %{^id => role}}} ->
          role

        _ ->
          nil
      end

    {old_role, process_event(:GUILD_ROLE_CREATE, data, shard_id, cache_provider)}
  end

  @typedoc """
    Emitted whenever a role was deleted.

    Emits a tuple of role and guild or guild id if uncached.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-role-delete).
  """
  @type guild_role_delete_event ::
          {:GUILD_ROLE_DELETE, Role.t() | {role_id(), Guild.t() | guild_id()}, shard_id()}

  def process_event(
        :GUILD_ROLE_DELETE,
        %{role_id: role_id, guild_id: guild_id},
        _shard_id,
        cache_provider
      ) do
    case cache_provider.guild_cache().fetch(guild_id) do
      {:ok, %{roles: %{^role_id => role}}} ->
        cache_provider.guild_cache().delete(role)
        role

      {:ok, guild} ->
        {role_id, guild}

      :error ->
        {role_id, guild_id}
    end
  end

  @typedoc """
    Emitted whenever a message was created. (Sent to a channel)

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#message-create).
  """
  @type message_create_event :: {:MESSAGE_CREATE, Message.t(), shard_id()}

  def process_event(:MESSAGE_CREATE, data, _shard_id, cache_provider) do
    # Map.get/2 because the key has to be present _and_ truthy (not nil)
    unless Map.get(data, :webhook_id), do: cache_provider.user_cache().insert(data.author)

    Enum.each(data.mentions, &cache_provider.user_cache().insert/1)

    Enum.each(
      data.mentions,
      fn
        %{id: id, member: member} when not is_nil(member) ->
          member
          |> Map.put(:guild_id, data.guild_id)
          |> Map.put(:user, %{id: id})
          |> Structs.create(Member)
          |> cache_provider.guild_cache().insert()

        _ ->
          nil
      end
    )

    message = Structs.create(data, Message)

    if message.member do
      cache_provider.guild_cache().insert(message.member)
    end

    message
  end

  @typedoc """
    Emitted whenever a message was updated.

    Emits a partial object for "embed update"s (discord auto embedding websites/images/videos)
    Or the full new message for "actual" message updates.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#message-update).
  """
  @type message_update_event ::
          {:MESSAGE_UPDATE,
           Message.t()
           | %{channel_id: channel_id(), id: message_id(), embeds: [term()]}, shard_id()}

  def process_event(:MESSAGE_UPDATE, %{author: _author} = data, _shard_id, _cache_provider) do
    Structs.create(data, Message)
  end

  # Embed update, only has channel_id, id, and embeds
  def process_event(:MESSAGE_UPDATE, data, _shard_id, _cache_provider) do
    data
    |> Map.update!(:id, &Util.id_to_int/1)
    |> Map.update!(:channel_id, &Util.id_to_int/1)
  end

  @typedoc """
    Emitted whenever a channel was deleted.

    Emits a tuple of channel and guild id if the channel was not cached.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#message-delete).
  """
  @type message_delete_event ::
          {:MESSAGE_DELETE, {message_id(), Channel.t() | {channel_id(), guild_id()}}, shard_id()}

  def process_event(
        :MESSAGE_DELETE,
        %{id: message_id, channel_id: channel_id, guild_id: guild_id},
        _shard_id,
        cache_provider
      ) do
    case cache_provider.channel_cache().fetch(channel_id) do
      {:ok, channel} ->
        {Util.id_to_int(message_id), channel}

      :error ->
        {Util.id_to_int(message_id), {channel_id, guild_id}}
    end
  end

  @typedoc """
    Emitted whenever a bulk of messages was deleted.

    Emits a tuple of channel and guild id if the channel was not cached.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#message-delete-bulk).
  """
  @type message_delete_bulk_event ::
          {:MESSAGE_DELETE_BULK, {[message_id()], Channel.t() | {channel_id(), guild_id()}},
           shard_id()}

  def process_event(
        :MESSAGE_DELETE_BULK,
        %{ids: ids, channel_id: channel_id} = data,
        _shard_id,
        cache_provider
      ) do
    case cache_provider.channel_cache().fetch(channel_id) do
      {:ok, channel} ->
        {Enum.map(ids, &Util.id_to_int/1), channel}

      :error ->
        {Enum.map(ids, &Util.id_to_int/1), {channel_id, Map.get(data, :guild_id)}}
    end
  end

  @typedoc """
    Emitted whenever a reaction was added to a message.

    Emits the user id if the user was not cached.
    Emits a tuple of channel and guild id if the channel was not cached.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#message-reaction-add).
  """
  @type message_reaction_add_event ::
          {:MESSAGE_REACTION_ADD,
           {User.t() | user_id(), Channel.t() | {channel_id(), guild_id()}, message_id(),
            Emoji.t()}, shard_id()}

  @typedoc """
    Emitted whenever a reaction was removed from a message.

    Emits the user id if the user was not cached.
    Emits a tuple of channel and guild id if the channel was not cached.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#message-reaction-remove).
  """
  @type message_reaction_remove_event ::
          {:MESSAGE_REACTION_REMOVE,
           {User.t() | user_id(), Channel.t() | {channel_id(), guild_id() | nil}, message_id(),
            Emoji.t()}, shard_id()}

  def process_event(type, data, _shard_id, cache_provider)
      when type in [:MESSAGE_REACTION_ADD, :MESSAGE_REACTION_REMOVE] do
    emoji =
      case cache_provider.emoji_cache().fetch(data.emoji.id) do
        {:ok, emoji} ->
          emoji

        :error ->
          Structs.create(data.emoji, Emoji)
      end

    user =
      case cache_provider.user_cache().fetch(data.user_id) do
        {:ok, user} ->
          user

        :error ->
          data.user_id
      end

    channel =
      case cache_provider.channel_cache().fetch(data.channel_id) do
        {:ok, channel} ->
          channel

        :error ->
          {data.channel_id, Map.get(data, :guild_id)}
      end

    {user, channel, data.message_id, emoji}
  end

  @typedoc """
    Emitted whenever a user explicitly removed all reactions from a message.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#message-reaction-remove-all).
  """
  @type message_reaction_remove_all_event ::
          {:MESSAGE_REACTION_REMOVE_ALL, {message_id(), Channel.t() | {channel_id(), guild_id()}}}

  def process_event(
        :MESSAGE_REACTION_REMOVE_ALL,
        %{channel_id: channel_id, message_id: message_id} = data,
        _shard_id,
        cache_provider
      ) do
    case cache_provider.channel_cache().fetch(channel_id) do
      {:ok, channel} ->
        {message_id, channel}

      :error ->
        {message_id, {channel_id, Map.get(data, :guild_id)}}
    end
  end

  @typedoc """
    Emitted whenever a user's presence or any of the user's properties updated.

    Emits presences for presence updates.
    Emits users for user updates.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#presence-update).
  """
  @type presence_update_event ::
          {:PRESENCE_UPDATE, {Presence.t() | nil, Presence.t()}, shard_id()}
          | {:PRESENCE_UPDATE, {User.t() | nil, User.t()}, shard_id()}

  def process_event(:PRESENCE_UPDATE, data, _shard_id, cache_provider) do
    old_user =
      data.user.id
      |> cache_provider.user_cache().fetch()
      |> case do
        {:ok, user} ->
          user

        :error ->
          nil
      end

    new_user =
      data.user
      |> cache_provider.user_cache().update()
      |> Structs.create(User)

    ret =
      if old_user == new_user do
        []
      else
        [{old_user, new_user}]
      end

    old_presence =
      case cache_provider.presence_cache().fetch(data.user.id) do
        {:ok, presence} ->
          presence

        :error ->
          nil
      end

    new_presence =
      data
      |> Map.put(:id, data.user.id)
      |> cache_provider.presence_cache().update()
      |> Structs.create(Presence)

    if old_presence == new_presence do
      ret
    else
      [{old_presence, new_presence} | ret]
    end
  end

  @typedoc """
    Emitted whenever a user started typing in a channel.

    Emits a tuple of channel and guild id if the channel was not cached.
    Emits the user id if the user was not cached.
    The third element is the unix timestamp of when the user started typing.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#typing-start).
  """
  @type typing_start_event ::
          {:TYPING_START,
           {Channel.t() | {channel_id(), guild_id() | nil}, User.t() | user_id(), String.t()},
           shard_id()}

  def process_event(:TYPING_START, data, _shard_id, cache_provider) do
    user =
      case cache_provider.user_cache().fetch(data.user_id) do
        {:ok, user} ->
          user

        :error ->
          data.user_id
      end

    channel =
      case cache_provider.channel_cache().fetch(data.channel_id) do
        {:ok, channel} ->
          channel

        :error ->
          {data.channel_id, Map.get(data, :guild_id)}
      end

    {channel, user, data.timestamp}
  end

  @typedoc """
    Emitted whenever properties about the current user changed.

    Emits nil as the user before the update if uncached previously.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#user-update).
  """
  @type user_update_event :: {:USER_UPDATE, {User.t() | nil, User.t()}, shard_id()}

  def process_event(:USER_UPDATE, data, _shard_id, cache_provider) do
    old_user =
      case cache_provider.user_cache().fetch(data.id) do
        {:ok, user} ->
          user

        :error ->
          nil
      end

    {old_user, cache_provider.user_cache().update(data)}
  end

  @typedoc """
    Emitted whenever the voice state of a member changed.

    Emits nil as the voice state before the update if uncached previously.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#voice-state-update).
  """
  @type voice_state_update_event ::
          {:VOICE_STATE_UPDATE, {VoiceState.t() | nil, VoiceState.t()}, shard_id()}

  def process_event(:VOICE_STATE_UPDATE, %{user_id: user_id} = data, _shard_id, cache_provider) do
    voice_state = Structs.create(data, VoiceState)

    case data do
      %{member: member} when not is_nil(member) ->
        member
        |> Map.put(:guild_id, voice_state.guild_id)
        |> Map.put(:user, %{id: voice_state.user_id})
        |> Structs.create(Member)
        |> cache_provider.guild_cache().insert()

      _ ->
        nil
    end

    old_voice_state =
      case cache_provider.guild_cache().fetch(data.guild_id) do
        {:ok, %{voice_states: %{^user_id => voice_state}}} ->
          voice_state

        _ ->
          nil
      end

    {old_voice_state, cache_provider.guild_cache().update(voice_state)}
  end

  @typedoc """
    Emitted whenever guild's voice server was updated.

    > This is the raw, but atomified, payload from discord, you can directly forward it to, for example, Lavalink.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#voice-server-update).
  """
  @type voice_server_update_event ::
          {:VOICE_SERVER_UPDATE, %{token: String.t(), guild_id: String.t(), endpoint: String.t()},
           shard_id()}

  def process_event(:VOICE_SERVER_UPDATE, data, _shard_id, _cache_provider), do: data

  @typedoc """
    Emitted whenever a channel's webhook was created, updated, or deleted.

    Emits the guild id if the guild was not cached.
    Emits the channel id if the channel was not cached.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#webhooks-update).
  """
  @type webhooks_update_event ::
          {:WEBHOOKS_UPDATE, {Guild.t() | guild_id(), Channel.t() | channel_id()}, shard_id()}

  def process_event(
        :WEBHOOKS_UPDATE,
        %{guild_id: guild_id, channel_id: channel_id},
        _shard_id,
        cache_provider
      ) do
    guild =
      case cache_provider.guild_cache().fetch(guild_id) do
        {:ok, guild} ->
          guild

        :error ->
          guild_id
      end

    channel =
      case cache_provider.channel_cache().fetch(channel_id) do
        {:ok, channel} ->
          channel

        :error ->
          channel_id
      end

    {guild, channel}
  end

  # User account only thing, for some reason bots do receive it sometimes as well, although always empty.
  def process_event(:PRESENCES_REPLACE, [], _shard_id, _cache_provider), do: nil

  def process_event(type, data, shard_id, _cache_provider) do
    require Logger

    Logger.warn(fn ->
      "[Crux][Base][Consumer] Unhandled type #{type} " <>
        "from shard #{shard_id}, with data #{inspect(data)}"
    end)

    data
  end
end
