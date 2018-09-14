defmodule Crux.Base.Consumer do
  @moduledoc """
    Handles consuming and processing of events received from the gateway.
    To consume those processed events subscribe with a consumer to a producer.
    You can fetch said producers via `Crux.Base.producers/0`
  """

  use GenStage

  alias Crux.Cache

  alias Crux.Structs
  alias Crux.Structs.{Channel, Emoji, Guild, Member, Message, Role, User, Util, VoiceState}

  @registry Crux.Base.Registry

  @doc false
  def start_link({shard_id, target}) do
    name = {:via, Registry, {@registry, {:consumer, shard_id}}}
    GenStage.start_link(__MODULE__, target, name: name)
  end

  @doc false
  def init(target) do
    {:consumer, nil, subscribe_to: [target]}
  end

  @doc false
  def handle_events(events, _from, nil) do
    for {type, data, shard_id} <- events,
        value <- [handle_event(type, data, shard_id)],
        value != nil do
      Crux.Base.Producer.dispatch({type, value, shard_id})
    end

    {:noreply, [], nil}
  end

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
    The guilds are not yet sent!

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

  @doc false
  def handle_event(:READY, data, _shard_id) do
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

  @typedoc """
    Emitted whenever a gateway connection resumed after unexpectedly disconnecting.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#resumed).
  """
  @type resumed_event :: {:RESUMED, %{_trace: [String.t()]}, shard_id()}

  def handle_event(:RESUMED, data, _shard_id), do: data

  @typedoc """
    Emitted whenever a channel was created.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#channel-create).
  """
  @type channel_create_event :: {:CHANNEL_CREATE, Channel.t(), shard_id()}

  def handle_event(:CHANNEL_CREATE, data, _shard_id) do
    channel =
      Cache.channel_cache().update(data)
      |> Structs.create(Channel)

    with %{guild_id: guild_id} when is_integer(guild_id) <- channel,
         do: Cache.guild_cache().insert(channel)

    channel
  end

  @typedoc """
    Emitted whenever a channel was updated.

    The first element is the channel before the update, or nil if not cached previously.
    The second element is the new channel.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#channel-update).
  """
  @type channel_update_event :: {:CHANNEL_UPDATE, {Channel.t() | nil, Channel.t()}, shard_id()}

  def handle_event(:CHANNEL_UPDATE, data, _shard_id) do
    old =
      case Cache.channel_cache().fetch(data.id) do
        {:ok, channel} ->
          channel

        :error ->
          nil
      end

    {old, Cache.channel_cache().update(data)}
  end

  @typedoc """
    Emitted whenever a channel was deleted.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#channel-delete).
  """
  @type channel_delete_event :: {:CHANNEL_DELETE, Channel.t(), shard_id()}

  def handle_event(:CHANNEL_DELETE, data, _shard_id) do
    channel = Structs.create(data, Channel)
    Cache.channel_cache().delete(data.id)

    with %{guild_id: guild_id} when is_integer(guild_id) <- data,
         do: Cache.guild_cache().delete(guild_id, channel)

    channel
  end

  @typedoc """
    Emitted whenever a message was pinned or unpinned.

    The first element is the channel id if the channel was not cached.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#channel-pins-update).
  """
  @type channel_pins_update_event ::
          {:CHANNEL_PINS_UPDATE, {Channel.t() | channel_id(), String.t() | nil}, shard_id()}

  def handle_event(:CHANNEL_PINS_UPDATE, %{channel_id: channel_id} = data, _shard_id) do
    case Cache.channel_cache().fetch(channel_id) do
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

    The first element is the guild before the update or nil if uncached previously.
    The second element is the guild after the update.

    Fore more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-update).
  """
  @type guild_update_event :: {:GUILD_UPDATE, {Guild.t() | nil, Guild.t()}, shard_id()}

  def handle_event(guild_event, data, _shard_id)
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

  @typedoc """
    Emitted whenever the client left a guild or a guild became unavailable.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-delete).
  """
  @type guild_delete_event :: {:GUILD_DELETE, Guild.t(), shard_id()}

  def handle_event(:GUILD_DELETE, data, shard_id) do
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

  @typedoc """
    Emitted whenever a user was banned from a guild.

    Emits the user if the member was not cached.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-ban-add).
  """
  @type guild_ban_add_event ::
          {:GUILD_BAN_ADD, {User.t() | Member.t(), Guild.t() | guild_id()}, shard_id()}

  def handle_event(:GUILD_BAN_ADD, %{guild_id: guild_id, user: %{id: id} = user}, _shard_id) do
    case Cache.guild_cache().fetch(guild_id) do
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

  For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-ban-removed).
  """
  @type guild_ban_remove_event ::
          {:GUILD_BAN_REMOVE, {User.t(), Guild.t() | guild_id()}, shard_id()}

  def handle_event(:GUILD_BAN_REMOVE, %{guild_id: guild_id, user: user}, _shard_id) do
    user = Structs.create(user, User)

    case Cache.guild_cache().fetch(guild_id) do
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

  def handle_event(:GUILD_EMOJIS_UPDATE, data, _shard_id) do
    old_emojis =
      for {:ok, %{emojis: emojis}} <- [Cache.guild_cache().fetch(data.guild_id)],
          emoji_id <- emojis,
          {:ok, emoji} <- [Cache.emoji_cache().fetch(emoji_id)] do
        emoji
      end

    emojis = Structs.create(data.emojis, Emoji)
    Cache.guild_cache().update({data.guild_id, {:emojis, emojis}})

    {old_emojis, emojis}
  end

  @typedoc """
    Emitted whenever one of a guild's integration was updated.

    Emits the guild id, if the guild was not cached.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-integrations-update).
  """
  @type guild_integrations_update_event ::
          {:GUILD_INTEGRATIONS_UPDATE, Guild.t() | guild_id(), shard_id()}

  def handle_event(:GUILD_INTEGRATIONS_UPDATE, %{guild_id: guild_id}, _shard_id) do
    case Cache.guild_cache().fetch(guild_id) do
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

  def handle_event(:GUILD_MEMBER_ADD, data, _shard_id) do
    data
    |> Structs.create(Member)
    |> Cache.guild_cache().update()
  end

  @typedoc """
    Emitted whenever a user left a guild.
    This includes kicks and bans.

    Emits the user if the member was not cached.

    The second element is the guild id, if the guild was not cached.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-member-remove).
  """
  @type guild_member_remove_event ::
          {:GUILD_MEMBER_REMOVE, {User.t() | Member.t(), Guild.t() | guild_id()}, shard_id()}

  def handle_event(:GUILD_MEMBER_REMOVE, %{guild_id: guild_id, user: %{id: id} = user}, _shard_id) do
    case Cache.guild_cache().fetch(guild_id) do
      {:ok, %{members: %{^id => member}} = guild} ->
        Cache.guild_cache().delete(guild_id, member)
        {member, guild}

      {:ok, guild} ->
        {Structs.create(user, User), guild}

      :error ->
        {Structs.create(user, User), guild_id}
    end
  end

  @typedoc """
    Emitted whenever a guild member was updated.

    The first element is the member before the update or nil if uncached previously.
    The second element is the member after the update.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-member-update).
  """
  @type guild_member_update_event ::
          {:GUILD_MEMBER_UPDATE, {Member.t() | nil, Member.t()}, shard_id()}

  def handle_event(:GUILD_MEMBER_UPDATE, data, _shard_id) do
    member = %{user: id} = Structs.create(data, Member)

    old_member =
      case Cache.guild_cache().fetch(member.guild_id) do
        {:ok, %{members: %{^id => old_member}}} ->
          old_member

        :error ->
          nil
      end

    {old_member, Cache.guild_cache().update(member)}
  end

  @typedoc """
    Emitted whenever a chunk of guild members was received.

    For more information see `Crux.Gateway.Command.request_guild_members/2` and [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-members-chunk).
  """
  @type guild_members_chunk_event :: {:GUILD_MEMBERS_CHUNK, [Member.t()], shard_id()}

  def handle_event(:GUILD_MEMBERS_CHUNK, data, _shard_id) do
    members = Structs.create(data.members, Member)

    Cache.guild_cache().update({data.guild_id, {:members, members}})
  end

  @typedoc """
    Emitted whenever a role was created.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-role-create).
  """
  @type guild_role_create_event :: {:GUILD_ROLE_CREATE, Role.t(), shard_id()}

  def handle_event(:GUILD_ROLE_CREATE, data, _shard_id) do
    role =
      data.role
      |> Map.put(:guild_id, data.guild_id)
      |> Structs.create(Role)

    Cache.guild_cache().update(role)
  end

  @typedoc """
    Emitted whenever a role was updated.

    The first element is the role before the update or nil if previously cached.
    The second element is the role after the update.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-role-update).
  """
  @type guild_role_update_event :: {:GUILD_ROLE_UPDATE, {Role.t() | nil, Role.t()}, shard_id()}

  def handle_event(:GUILD_ROLE_UPDATE, %{guild_id: guild_id, role: %{id: id}} = data, shard_id) do
    old_role =
      case Cache.guild_cache().fetch(guild_id) do
        {:ok, %{roles: %{^id => role}}} ->
          role

        _ ->
          nil
      end

    {old_role, handle_event(:GUILD_ROLE_CREATE, data, shard_id)}
  end

  @typedoc """
    Emitted whenever a role was deleted.

    If the role is not cached emits a tuple of the role id and if not cached the guild id, or guild.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#guild-role-delete).
  """
  @type guild_role_delete_event ::
          {:GUILD_ROLE_DELETE, Role.t() | {role_id(), Guild.t() | guild_id()}, shard_id()}

  def handle_event(:GUILD_ROLE_DELETE, %{role_id: role_id, guild_id: guild_id}, _shard_id) do
    case Cache.guild_cache().fetch(guild_id) do
      {:ok, %{roles: %{^role_id => role}}} ->
        Cache.guild_cache().delete(guild_id, role)
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

  def handle_event(:MESSAGE_CREATE, data, _shard_id) do
    # Map.get/2 because the key has to be present _and_ truthy (not nil)
    unless Map.get(data, :webhook_id), do: Cache.user_cache().insert(data.author)

    Enum.each(data.mentions, &Cache.user_cache().insert/1)

    message = Structs.create(data, Message)

    Enum.each(
      data.mentions,
      fn
        %{id: id, member: member} when not is_nil(member) ->
          member
          |> Map.put(:guild_id, message.guild_id)
          |> Map.put(:user, %{id: id})
          |> Structs.create(Member)
          |> Cache.guild_cache().insert()

        _ ->
          nil
      end
    )

    with %{member: member} when not is_nil(member) <- message,
         do: Cache.guild_cache().insert(member)

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

  def handle_event(:MESSAGE_UPDATE, %{author: _author} = data, _shard_id) do
    Structs.create(data, Message)
  end

  # Embed update, only has channel_id, id, and embeds
  def handle_event(:MESSAGE_UPDATE, data, _shard_id) do
    data
    |> Map.update!(:id, &Util.id_to_int/1)
    |> Map.update!(:channel_id, &Util.id_to_int/1)
  end

  @typedoc """
    Emitted whenever a channel was deleted.

    Emits as second element a tuple of channel and guild id if the channel was not cached.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#message-delete).
  """
  @type message_delete_event ::
          {:MESSAGE_DELETE, {message_id(), Channel.t() | {channel_id(), guild_id()}}, shard_id()}

  def handle_event(
        :MESSAGE_DELETE,
        %{id: message_id, channel_id: channel_id, guild_id: guild_id},
        _shard_id
      ) do
    case Cache.channel_cache().fetch(channel_id) do
      {:ok, channel} ->
        {message_id |> Util.id_to_int(), channel}

      :error ->
        {message_id |> Util.id_to_int(), {channel_id, guild_id}}
    end
  end

  @typedoc """
    Emitted whenever a bulk of messages was deleted.

    Emits the channel id if the channel was not cached.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#message-delete-bulk).
  """
  @type message_delete_bulk_event ::
          {:MESSAGE_DELETE_BULK, {[message_id()], Channel.t() | {channel_id(), guild_id()}},
           shard_id()}

  def handle_event(
        :MESSAGE_DELETE_BULK,
        %{ids: ids, channel_id: channel_id} = data,
        _shard_id
      ) do
    case Cache.channel_cache().fetch(channel_id) do
      {:ok, channel} ->
        {ids |> Enum.map(&Util.id_to_int/1), channel}

      :error ->
        {ids |> Enum.map(&Util.id_to_int/1), {channel_id, Map.get(data, :guild_id)}}
    end
  end

  @typedoc """
    Emitted whenever a reaction was added to a message.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#message-reaction-add).
  """
  @type message_reaction_add_event ::
          {:MESSAGE_REACTION_ADD,
           {User.t() | user_id(), Channel.t() | channel_id(), message_id(), Emoji.t()},
           shard_id()}

  @typedoc """
    Emitted whenever a reaction was removed from a message.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#message-reaction-remove).
  """
  @type message_reaction_remove_event ::
          {:MESSAGE_REACTION_REMOVE, {User.t(), Channel.t(), message_id(), Emoji.t()}, shard_id()}

  def handle_event(type, data, _shard_id)
      when type in [:MESSAGE_REACTION_ADD, :MESSAGE_REACTION_REMOVE] do
    emoji =
      with id when not is_nil(id) <- data.emoji.id,
           {:ok, emoji} <- Cache.emoji_cache().fetch(id) do
        emoji
      else
        _ ->
          Structs.create(data.emoji, Emoji)
      end

    user =
      case Cache.user_cache().fetch(data.user_id) do
        {:ok, user} ->
          user

        :error ->
          data.user_id
      end

    channel =
      case Cache.channel_cache().fetch(data.channel_id) do
        {:ok, channel} ->
          channel

        :error ->
          data.channel_id
      end

    {user, channel, data.message_id, emoji}
  end

  @typedoc """
    Emitted whenever a user explicitly removed all reactions from a message.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#message-reaction-remove-all).
  """
  @type message_reaction_remove_all_event ::
          {:MESSAGE_REACTION_REMOVE_ALL, {message_id(), Channel.t() | channel_id()}}

  def handle_event(
        :MESSAGE_REACTION_REMOVE_ALL,
        %{channel_id: channel_id, message_id: message_id},
        _shard_id
      ) do
    case Cache.channel_cache().fetch(channel_id) do
      {:ok, channel} ->
        {message_id, channel}

      :error ->
        {message_id, channel_id}
    end
  end

  @typedoc """
    Emitted whenever a user's presence updated.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#presence-update).
  """
  @type presence_update_event ::
          {:PRESENCE_UPDATE, {Presence.t() | nil, Presence.t()}, shard_id()}

  # TODO: This also propagates roles / username / etc changes. Would be nice to see the difference here in a sane manner.
  def handle_event(:PRESENCE_UPDATE, data, _shard_id) do
    old_presence =
      case Cache.presence_cache().fetch(data.user.id) do
        {:ok, presence} ->
          presence

        :error ->
          nil
      end

    presence =
      data
      |> Map.put(:id, data.user.id)
      |> Cache.presence_cache().update()

    user =
      Cache.user_cache().update(data.user)
      |> Structs.create(User)

    with %{roles: roles, guild_id: guild_id} <- data do
      Cache.guild_cache().insert({guild_id, {user, roles}})
    end

    {old_presence, presence}
  end

  @typedoc """
    Emitted whenever a user started typing in a channel.

    The first element is the channel id if the channel was not cached.
    The second element is the user id if the user was not cached.
    The third element is the timestamp of when the user started typing.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#typing-start).
  """
  @type typing_start_event ::
          {:TYPING_START, {Channel.t() | channel_id(), User.t() | user_id(), String.t()},
           shard_id()}

  def handle_event(:TYPING_START, data, _shard_id) do
    user =
      case Cache.user_cache().fetch(data.user_id) do
        {:ok, user} ->
          user

        :error ->
          data.user_id
      end

    channel =
      case Cache.channel_cache().fetch(data.channel_id) do
        {:ok, channel} ->
          channel

        :error ->
          data.channel_id
      end

    {channel, user, data.timestamp}
  end

  @typedoc """
    Emitted whenever properties about the current user changed.

    The first element is the user before the update or nil if previously cached.
    The second element is the user after the update.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#user-update).
  """
  @type user_update_event :: {:USER_UPDATE, {User.t() | nil, User.t()}, shard_id()}

  def handle_event(:USER_UPDATE, data, _shard_id) do
    old_user =
      case Cache.user_cache().fetch(data.id) do
        {:ok, user} ->
          user

        :error ->
          nil
      end

    {old_user, Cache.user_cache().update(data)}
  end

  @typedoc """
    Emitted whenever the voice state of a member changed.

    The first element is the voice state before the update or nil if previously cached.
    The second element is the voice state after the update.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#voice-state-update).
  """
  @type voice_state_update_event ::
          {:VOICE_STATE_UPDATE, {VoiceState.t() | nil, VoiceState.t()}, shard_id()}

  def handle_event(:VOICE_STATE_UPDATE, %{user_id: user_id} = data, _shard_id) do
    voice_state = Structs.create(data, VoiceState)

    old_voice_state =
      case Cache.guild_cache().fetch(data.guild_id) do
        {:ok, %{voice_states: %{^user_id => voice_state}}} ->
          voice_state

        _ ->
          nil
      end

    {old_voice_state, Cache.guild_cache().update(voice_state)}
  end

  @typedoc """
    Emitted whenever guild's voice server was updated.

    > This is the raw, but atomified, payload from discord, you can directly forward it to, for example, Lavalink.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#voice-server-update).
  """
  @type voice_server_update_event ::
          {:VOICE_SERVER_UPDATE, %{token: String.t(), guild_id: String.t(), endpoint: String.t()},
           shard_id()}

  def handle_event(:VOICE_SERVER_UPDATE, data, _shard_id), do: data

  @typedoc """
    Emitted whenever a channel's webhook was created, updated, or deleted.

    Emits the guild id if the guild was not cached.
    Emits the channel id if the channel was not cached.

    For more information see [Discord Docs](https://discordapp.com/developers/docs/topics/gateway#webhooks-update).
  """
  @type webhooks_update_event ::
          {:WEBHOOKS_UPDATE, {Guild.t() | guild_id(), Channel.t() | channel_id()}, shard_id()}

  def handle_event(:WEBHOOKS_UPDATE, %{guild_id: guild_id, channel_id: channel_id}, _shard_id) do
    guild =
      case Cache.guild_cache().fetch(guild_id) do
        {:ok, guild} ->
          guild

        :error ->
          guild_id
      end

    channel =
      case Cache.channel_cache().fetch(channel_id) do
        {:ok, channel} ->
          channel

        :error ->
          channel_id
      end

    {guild, channel}
  end

  # User account only thing, for some reason bots do receive it, although empty, sometimes as well.
  def handle_event(:PRESENCES_REPLACE, [], _shard_id), do: nil

  def handle_event(type, data, shard_id) do
    require Logger

    Logger.warn(
      "[Crux][Base][Consumer] Unhandled type #{type} " <>
        "from shard #{shard_id}, with data #{inspect(data)}"
    )

    data
  end
end
