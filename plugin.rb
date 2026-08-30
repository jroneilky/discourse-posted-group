# name: discourse-posted-group
# about: Automatically adds users to the "posted" group once they've made at least one post or reply
# version: 1.2
# authors: jronieleky

after_initialize do
  # Moved inside the block to prevent polluting the global Ruby namespace
  target_group_name = "posted"
  count_private_messages = false

  DiscourseEvent.on(:post_created) do |post, _opts, user|
    begin
      next if post.blank? || user.blank?
      next if user.bot?
      next if post.post_type != Post.types[:regular]
      next if post.topic.blank?
      next if !count_private_messages && post.topic.private_message?

      # PERFORMANCE: Check if the user is already in the group first.
      # If the user's groups are already loaded in memory, this prevents a DB hit.
      next if user.groups.any? { |g| g.name == target_group_name }

      group = Group.find_by(name: target_group_name)
      
      if group.blank?
        Rails.logger.warn("[add-to-posted-group] Group '#{target_group_name}' not found — skipping.")
        next
      end

      # Final database check just in case the group wasn't loaded in user.groups
      next if GroupUser.exists?(group_id: group.id, user_id: user.id)

      group.add(user)
    rescue => e
      Rails.logger.error("[add-to-posted-group] Failed on post #{post&.id}: #{e.class} #{e.message}")
    end
  end
end
