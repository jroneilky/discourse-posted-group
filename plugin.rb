# frozen_string_literal: true

# name: discourse_posted_group
# about: Automatically adds users to groups based on their public post count.
# version: 1.0.0
# authors: jroneilky
# contact email:
# url: https://github.com/jroneilky/discourse_posted_group
# license: MIT

enabled_site_setting :discourse_posted_group_enabled

after_initialize do
  module ::DiscoursePostedGroup
    GROUP_POSTED    = "posted"
    GROUP_POSTED_10 = "posted_10"

    class << self
      def update_groups(user)
        return if user.blank?
        return if user.bot?
        return if user.staged?

        add_to_group(user, GROUP_POSTED)    { public_posts_scope(user).limit(1).exists? }
        add_to_group(user, GROUP_POSTED_10) { public_posts_scope(user).offset(9).limit(1).exists? }
      end

      private

      def add_to_group(user, group_name)
        group = ensure_group(group_name)
        return if group.blank?
        return if group_member?(group, user)

        return unless yield

        group.add(user)
      rescue StandardError => e
        Rails.logger.error("discourse_posted_group: failed to add user #{user.id} to '#{group_name}': #{e.message}")
      end

      def ensure_group(name)
        Group.find_by(name: name) || create_group(name)
      end

      def create_group(name)
        Group.create!(
          name: name,
          full_name: name.titleize,
          visibility_level: Group.visibility_levels[:members],
          automatic: false
        )
      rescue StandardError => e
        Rails.logger.error("discourse_posted_group: failed to create group '#{name}': #{e.message}")
        nil
      end

      def group_member?(group, user)
        GroupUser.exists?(group_id: group.id, user_id: user.id)
      end

      def public_posts_scope(user)
        Post.joins(:topic)
            .where(user_id: user.id, deleted_at: nil)
            .where(post_type: Post.types[:regular])
            .where.not(topics: { archetype: Archetype.private_message })
      end
    end
  end

  on(:post_created) do |post, opts|
    next unless SiteSetting.discourse_posted_group_enabled
    next if post.blank?
    next if post.user.blank?

    user = post.user
    next if user.bot?
    next if user.staged?
    next if post.topic&.private_message?
    next if post.whisper?

    DiscoursePostedGroup.update_groups(user)
  rescue StandardError => e
    Rails.logger.error("discourse_posted_group: post_created handler failed for post #{post&.id}: #{e.message}")
  end

  if SiteSetting.discourse_posted_group_enabled
    DistributedMutex.synchronize("discourse_posted_group_backfill", validity: 60) do
      if PluginStore.get("discourse_posted_group", "backfilled_at").blank?
        Jobs.enqueue(:discourse_posted_group_backfill)
        PluginStore.set("discourse_posted_group", "backfilled_at", Time.now.to_i)
      end
    end
  end
end

module ::Jobs
  class DiscoursePostedGroupBackfill < ::Jobs::Base
    def execute(args = {})
      return unless SiteSetting.discourse_posted_group_enabled

      User.real.not_staged
          .joins(:user_stat)
          .where("user_stats.post_count > 0")
          .find_each do |user|
        DiscoursePostedGroup.update_groups(user)
      end
    rescue StandardError => e
      Rails.logger.error("discourse_posted_group: backfill failed: #{e.message}")
    end
  end
end
