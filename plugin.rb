# frozen_string_literal: true

# name: discourse_posted_group
# about: Automatically adds users to groups based on their public post count.
# version: 1.1
# authors: jroneilky
# contact_emails:
# url: https://github.com/jroneilky/discourse_posted_group

enabled_site_setting :discourse_posted_group_enabled

after_initialize do
  module ::DiscoursePostedGroup
    GROUP_POSTED    = "posted"
    GROUP_POSTED_10 = "posted_10"

    class << self
      def update_groups(user)
        return if user.blank? || user.bot? || user.staged?

        count = public_posts_count(user)
        add_to_group(user, GROUP_POSTED, count >= 1)
        add_to_group(user, GROUP_POSTED_10, count >= 10)
      end

      def handle_post_event(post)
        return unless SiteSetting.discourse_posted_group_enabled
        return if post.blank? || post.topic.blank? || post.user.blank?

        user = post.user
        return if user.bot? || user.staged?
        return if post.topic.private_message?
        return unless post.post_type == Post.types[:regular]

        update_groups(user)
      rescue StandardError => e
        Rails.logger.error("discourse_posted_group: post handler failed for post #{post&.id}: #{e.message}")
      end

      def ensure_group(name)
        Group.find_by(name: name) || create_group(name)
      end

      def public_post_user_ids
        Post.joins(:topic)
            .where(deleted_at: nil)
            .where(post_type: Post.types[:regular])
            .where.not(topics: { archetype: Archetype.private_message })
            .where(topics: { deleted_at: nil })
            .distinct
            .pluck(:user_id)
      end

      private

      def add_to_group(user, group_name, should_add)
        group = ensure_group(group_name)
        return if group.blank?

        is_member = group_member?(group, user)

        if should_add && !is_member
          group.add(user)
        elsif !should_add && is_member
          group.remove(user)
        end
      rescue StandardError => e
        Rails.logger.error("discourse_posted_group: failed to update membership for user #{user.id} in '#{group_name}': #{e.message}")
      end

      def create_group(name)
        Group.create!(
          name: name,
          full_name: name.titleize,
          visibility_level: Group.visibility_levels[:members],
          members_visibility_level: Group.visibility_levels[:members],
          automatic: false
        )
      rescue ActiveRecord::RecordNotUnique => e
        Rails.logger.warn("discourse_posted_group: race creating group '#{name}': #{e.message}")
        Group.find_by(name: name)
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error("discourse_posted_group: failed to create group '#{name}': #{e.message}")
        nil
      end

      def group_member?(group, user)
        GroupUser.exists?(group_id: group.id, user_id: user.id)
      end

      def public_posts_count(user)
        public_posts_scope(user).count
      end

      def public_posts_scope(user)
        Post.joins(:topic)
            .where(user_id: user.id, deleted_at: nil)
            .where(post_type: Post.types[:regular])
            .where.not(topics: { archetype: Archetype.private_message })
            .where(topics: { deleted_at: nil })
      end
    end
  end

  on(:post_created)   { |post, opts| ::DiscoursePostedGroup.handle_post_event(post) }
  on(:post_destroyed) { |post, opts| ::DiscoursePostedGroup.handle_post_event(post) }
  on(:post_recovered) { |post, opts| ::DiscoursePostedGroup.handle_post_event(post) }

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

      group_posted = ::DiscoursePostedGroup.ensure_group(::DiscoursePostedGroup::GROUP_POSTED)
      group_posted_10 = ::DiscoursePostedGroup.ensure_group(::DiscoursePostedGroup::GROUP_POSTED_10)
      return if group_posted.blank? || group_posted_10.blank?

      candidate_ids = ::DiscoursePostedGroup.public_post_user_ids
      member_ids = GroupUser.where(group_id: [group_posted.id, group_posted_10.id]).distinct.pluck(:user_id)

      User.real.not_staged.where(id: (candidate_ids + member_ids).uniq).find_each do |user|
        ::DiscoursePostedGroup.update_groups(user)
      end
    rescue StandardError => e
      Rails.logger.error("discourse_posted_group: backfill failed: #{e.message}")
    end
  end
end
