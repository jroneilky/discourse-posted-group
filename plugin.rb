# name: discourse-posted-group
# about: Automatically adds users to the "posted" group once they've made at least one post or reply
# version: 1.3
# authors: jronieleky

after_initialize do
  group_1_name = "posted"
  group_10_name = "posted_10"
  count_private_messages = false

  DiscourseEvent.on(:post_created) do |post, _opts, user|
    begin
      next if post.blank? || user.blank?
      next if user.bot?
      next if post.post_type != Post.types[:regular]
      next if post.topic.blank?
      next if !count_private_messages && post.topic.private_message?

      # Extract group names currently loaded in memory to prevent N+1 queries
      user_group_names = user.groups.map(&:name)
      
      # Reusable logic block for safely adding a user to a group
      add_to_group = ->(group_name) do
        next if user_group_names.include?(group_name)
        
        group = Group.find_by(name: group_name)
        if group.blank?
          Rails.logger.warn("[add-to-posted-group] Group '#{group_name}' not found — skipping.")
          next
        end

        # Final database check to prevent duplicate key errors
        group.add(user) unless GroupUser.exists?(group_id: group.id, user_id: user.id)
      end

      # Evaluate 1st post threshold
      add_to_group.call(group_1_name)

      # Evaluate 10th post threshold
      if user.user_stat && user.user_stat.post_count >= 10
        add_to_group.call(group_10_name)
      end

    rescue => e
      Rails.logger.error("[add-to-posted-group] Failed on post #{post&.id}: #{e.class} #{e.message}")
    end
  end
end
