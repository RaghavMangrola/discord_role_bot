require 'discordrb'
require 'dotenv'
require 'json'

Dotenv.load

DATA_FILE = 'role_data.json'

def load_data
  if File.exist?(DATA_FILE) && !File.zero?(DATA_FILE)
    begin
      JSON.parse(File.read(DATA_FILE))
    rescue JSON::ParserError => e
      puts "Error parsing JSON file: #{e.message}"
      puts "Initializing with empty data"
      { 'role_emoji_map' => {}, 'role_messages' => {} }
    end
  else
    puts "Data file not found or empty. Initializing with empty data."
    { 'role_emoji_map' => {}, 'role_messages' => {} }
  end
end

def save_data(data)
  File.write(DATA_FILE, JSON.pretty_generate(data))
end

data = load_data
role_emoji_map = data['role_emoji_map']
role_messages = data['role_messages']

def create_role_if_not_exists(server, role_name)
  role = server.roles.find { |r| r.name == role_name }
  unless role
    role = server.create_role(name: role_name)
    puts "Created new role: #{role_name}"
  end
  role
end

def update_role_selection_message(bot, guild_id, role_messages, role_emoji_map)
  role_message_data = role_messages[guild_id]
  return unless role_message_data

  channel = bot.channel(role_message_data['channel_id'])
  message = channel.load_message(role_message_data['message_id'])
  
  guild_roles = role_emoji_map[guild_id]
  
  message_content = "React for roles:\n\n"
  guild_roles.each do |emoji, role_name|
    message_content += "#{emoji} - #{role_name}\n"
  end

  message.edit(message_content)
  
  # Get current reactions
  current_reactions = message.reactions.map { |r| r.emoji.name }
  puts "Debug: Current reactions: #{current_reactions}"

  # Remove old reactions
  current_reactions.each do |emoji_name|
    unless guild_roles.key?(emoji_name)
      puts "Debug: Removing reaction for emoji: #{emoji_name}"
      begin
        message.delete_own_reaction(emoji_name)
      rescue => e
        puts "Error removing reaction: #{e.message}"
      end
    end
  end

  # Add new reactions
  guild_roles.each_key do |emoji|
    unless current_reactions.include?(emoji)
      puts "Debug: Adding reaction for emoji: #{emoji}"
      begin
        message.create_reaction(emoji)
      rescue => e
        puts "Error adding reaction: #{e.message}"
      end
    end
  end
end

bot = Discordrb::Bot.new token: ENV['DISCORD_BOT_TOKEN'], intents: [:servers, :server_messages, :server_message_reactions, :server_members, :direct_messages]

bot.ready do
  puts "Bot is ready!"
end

bot.register_application_command(:addrole, 'Add a role mapping') do |cmd|
  cmd.string('emoji', 'The emoji for the role', required: true)
  cmd.string('role_name', 'The name of the role', required: true)
end

bot.application_command(:addrole) do |event|
  next unless event.user.permission?(:administrator)

  emoji = event.options['emoji']
  role_name = event.options['role_name']
  guild_id = event.server_id.to_s

  puts "Debug: Received addrole command"
  puts "Debug: emoji = #{emoji}"
  puts "Debug: role_name = #{role_name}"
  puts "Debug: guild_id = #{guild_id}"

  # Create the role if it doesn't exist
  role = create_role_if_not_exists(event.server, role_name)
  puts "Debug: Role created or found: #{role.name}"

  role_emoji_map[guild_id] ||= {}
  role_emoji_map[guild_id][emoji] = role_name

  save_data({ 'role_emoji_map' => role_emoji_map, 'role_messages' => role_messages })
  puts "Debug: Data saved"

  update_role_selection_message(bot, guild_id, role_messages, role_emoji_map)
  puts "Debug: Role selection message updated"

  event.respond(content: "Role mapping added: #{emoji} -> #{role_name}")
  puts "Debug: Response sent"
end

bot.register_application_command(:removerole, 'Remove a role mapping') do |cmd|
  cmd.string('emoji', 'The emoji of the role mapping to remove', required: true)
end

bot.application_command(:removerole) do |event|
  next unless event.user.permission?(:administrator)

  emoji = event.options['emoji']
  guild_id = event.server_id.to_s

  puts "Debug: Removing role for emoji: #{emoji}"
  puts "Debug: Current role_emoji_map: #{role_emoji_map[guild_id]}"

  if role_emoji_map[guild_id] && role_emoji_map[guild_id][emoji]
    role_name = role_emoji_map[guild_id][emoji]
    role_emoji_map[guild_id].delete(emoji)
    save_data({ 'role_emoji_map' => role_emoji_map, 'role_messages' => role_messages })
    
    puts "Debug: Role mapping removed. Updated role_emoji_map: #{role_emoji_map[guild_id]}"
    update_role_selection_message(bot, guild_id, role_messages, role_emoji_map)
    puts "Debug: Role selection message updated"
    
    event.respond(content: "Role mapping removed for emoji: #{emoji}")
  else
    puts "Debug: Role mapping not found for emoji: #{emoji}"
    event.respond(content: 'Role mapping not found.')
  end
end

bot.register_application_command(:listroles, 'List all role mappings')

bot.application_command(:listroles) do |event|
  next unless event.user.permission?(:administrator)

  guild_id = event.server_id.to_s
  guild_roles = role_emoji_map[guild_id]

  if guild_roles.nil? || guild_roles.empty?
    event.respond(content: 'No role mappings set up.')
    next
  end

  response = "Current role mappings:\n"
  guild_roles.each do |emoji, role_name|
    response += "#{emoji} -> #{role_name}\n"
  end

  event.respond(content: response)
end

bot.register_application_command(:setchannel, 'Create a message for role selection') do |cmd|
  cmd.string('channel_id', 'The ID of the channel to post the message in', required: true)
end

bot.application_command(:setchannel) do |event|
  next unless event.user.permission?(:administrator)

  guild_id = event.server_id.to_s
  channel_id = event.options['channel_id']

  puts "Debug: Received setchannel command"
  puts "Debug: guild_id = #{guild_id}"
  puts "Debug: channel_id = #{channel_id}"

  # Verify the channel exists
  channel = event.server.channels.find { |c| c.id.to_s == channel_id }
  unless channel
    puts "Debug: Channel not found"
    event.respond(content: "Channel not found. Please use a valid channel ID.", ephemeral: true)
    next
  end

  guild_roles = role_emoji_map[guild_id]

  if guild_roles.nil? || guild_roles.empty?
    puts "Debug: No role mappings found"
    event.respond(content: 'No role mappings set up. Use /addrole to add role mappings first.')
    next
  end

  message_content = "React for roles:\n\n"
  guild_roles.each do |emoji, role_name|
    message_content += "#{emoji} - #{role_name}\n"
  end

  puts "Debug: Sending role selection message"
  role_message = channel.send_message(message_content)
  guild_roles.each_key do |emoji|
    role_message.create_reaction(emoji)
  end

  role_messages[guild_id] = { channel_id: channel_id, message_id: role_message.id.to_s }
  save_data({ 'role_emoji_map' => role_emoji_map, 'role_messages' => role_messages })
  puts "Debug: Data saved"

  event.respond(content: "Role selection message created in <##{channel_id}>.")
  puts "Debug: Response sent"
end

bot.reaction_add do |event|
  puts "Event triggered for reaction add"
  
  next if event.user.bot_account?
  puts "User is not a bot account"
  
  guild_id = event.server.id.to_s
  emoji = event.emoji.name
  puts "Guild ID: #{guild_id}, Emoji: #{emoji}"
  
  role_message = role_messages[guild_id]
  unless role_message
    puts "No role message found for guild ID: #{guild_id}"
    next
  end
  
  if role_message['message_id'] != event.message.id.to_s
    puts "Message ID does not match for role message"
    next˚
  end
  
  puts "Role message found and message ID matches"
  
  guild_roles = role_emoji_map[guild_id]
  unless guild_roles
    puts "No guild roles found for guild ID: #{guild_id}"
    next
  end
  
  unless guild_roles[emoji]
    puts "No role mapped for emoji: #{emoji}"
    next
  end
  
  role_name = guild_roles[emoji]
  role = create_role_if_not_exists(event.server, role_name)
  puts "Role name: #{role_name}, Role: #{role.inspect}"
  
  if role
    event.user.add_role(role)
    event.user.dm("You've been granted the #{role_name} role!")
    puts "Role #{role_name} granted to user #{event.user.name}"
  else
    event.user.dm("There was an error granting the #{role_name} role.")
    puts "Error granting role #{role_name} to user #{event.user.name}"
  end
end


bot.reaction_remove do |event|
  next if event.user.bot_account?

  guild_id = event.server.id.to_s
  emoji = event.emoji.name

  role_message = role_messages[guild_id]
  next unless role_message && role_message['message_id'] == event.message.id.to_s

  guild_roles = role_emoji_map[guild_id]
  next unless guild_roles && guild_roles[emoji]

  role_name = guild_roles[emoji]
  role = event.server.roles.find { |r| r.name == role_name }

  if role
    event.user.remove_role(role)
    puts "Debug: Removed role #{role_name} from user #{event.user.name}"
    event.user.dm("You've been removed from the #{role_name} role.")
  else
    puts "Debug: Role #{role_name} not found for removal"
  end
end

bot.run