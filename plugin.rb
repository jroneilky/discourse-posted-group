# plugin.rb
# frozen_string_literal: true

# name: discourse-posted-group
# about: Adds users to milestone groups based on reply count (e.g. "posted" on 1st reply, "posted_10" on Nth reply)
# version: 1.5
# authors: jronielky
# url: https://github.com/yourname/discourse-posted-group
# required_version: 2.7.0

enabled_site_setting :posted_group_enabled

after_initialize do
  module ::PostedGroup
    def self.thresholds
      SiteSetting.posted_group_thresholds.to_s.split("|").each_with_object({}) do |pair, h|
        raw_threshold, name = pair.split(":", 2)
        t = raw_threshold.to_i
        h[t] = name if t >= 1 && name.present?
      end
    end

    def self.max_threshold
      thresholds.keys.max
    end

    def self.top_group_name
      max_t = max_threshold
      return nil if max_t.blank?
      thresholds[max_t]
    end

    def self.ensure_groups_exist!
      thresholds.values.uniq.each do |name|
        next if Group.exists?(name: name)
        Group.create!(name: name, visible: true)
      rescue => e
        Rails.logger.warn("[posted_group] could not create group '#{name}': #{e.message}")
      end
    rescue => e
      Rails.logger.warn("[posted_group] ensure_groups_exist! skipped: #{e.message}")
    end

    def self.qualifying_post?(post)
      return false if post.blank?
      return false if post.post_type != Post.types[:regular]
      return false if post.post_number.to_i <= 1 # OP isn't a "reply"
      return false if post.user_id.to_i <= 0

      user = post.user
      return false if user.blank? || user.bot? || user.staged?

      topic = post.topic
      return false if topic.blank? || topic.deleted_at.present?
      return false if topic.archetype != Archetype.default # skip PMs

      true
    end

    # Cheapest possible check: is the user already done with all milestones?
    # If so, we never need to touch the replies cache or count anything again.
    def self.already_maxed?(user)
      name = top_group_name
      return false if name.blank?

      group_id = Group.where(name: name).pick(:id)
      return false if group_id.blank?

      GroupUser.exists?(group_id: group_id, user_id: user.id)
    end

    def self.record_reply(post)
      return unless qualifying_post?(post)

      max_t = max_threshold
      return if max_t.blank?

      # Safety-net cap: never let a single user accumulate more rows than
      # the highest threshold needs, even if group assignment lags behind.
      DB.exec(<<~SQL, post_id: post.id, user_id: post.user_id, max_t: max_t)
        INSERT INTO posted_group_replies (post_id, user_id)
        SELECT :post_id, :user_id
        WHERE (SELECT COUNT(*) FROM posted_group_replies WHERE user_id = :user_id) < :max_t
        ON CONFLICT (post_id) DO NOTHING
      SQL
    end

    def self.remove_reply(post_id)
      DB.exec("DELETE FROM posted_group_replies WHERE post_id = :post_id", post_id: post_id)
    end

    def self.reply_count(user_id)
      DB.query_single(
        "SELECT COUNT(*) FROM posted_group_replies WHERE user_id = :user_id",
        user_id: user_id
      ).first.to_i
    end

    def self.sync_user_groups!(user)
      return if user.blank? || user.bot? || user.staged?

      current = thresholds
      return if current.empty?

      names = current.values.uniq
      already_in = GroupUser.joins(:group)
                             .where(user_id: user.id, groups: { name: names })
                             .pluck("groups.name")

      targets = current.reject { |_, name| already_in.include?(name) }
      return if targets.empty?

      count = reply_count(user.id)

      targets.each do |threshold, group_name|
        next unless count >= threshold
        group = Group.find_by(name: group_name)
        next if group.blank?
        next if GroupUser.exists?(group_id: group.id, user_id: user.id)

        begin
          group.add(user)
        rescue ActiveRecord::RecordNotUnique
          # added concurrently, ignore
        end
      end
    end

    def self.handle_post_created(post_id)
      post = Post.find_by(id: post_id)
      return if post.blank?

      user = post.user
      return if user.blank?
      return if already_maxed?(user) # nothing left to track for this user

      record_reply(post)
      sync_user_groups!(user)
    rescue => e
      Rails.logger.warn("[posted_group] create handling failed for post #{post_id}: #{e.message}")
    end

    def self.handle_post_destroyed(post_id)
      remove_reply(post_id)
    rescue => e
      Rails.logger.warn("[posted_group] destroy handling failed for post #{post_id}: #{e.message}")
    end

    def self.handle_post_recovered(post_id)
      post = Post.find_by(id: post_id)
      return if post.blank?

      user = post.user
      return if user.blank?
      return if already_maxed?(user)

      record_reply(post)
      sync_user_groups!(user)
    rescue => e
      Rails.logger.warn("[posted_group] recover handling failed for post #{post_id}: #{e.message}")
    end
  end

  module ::Jobs
    class PostedGroupPostCreated < ::Jobs::Base
      def execute(args)
        return unless SiteSetting.posted_group_enabled
        PostedGroup.handle_post_created(args[:post_id])
      end
    end

    class PostedGroupPostRecovered < ::Jobs::Base
      def execute(args)
        return unless SiteSetting.posted_group_enabled
        PostedGroup.handle_post_recovered(args[:post_id])
      end
    end
  end

  PostedGroup.ensure_groups_exist!

  on(:post_created) do |post, _opts, _user|
    next unless SiteSetting.posted_group_enabled
    Jobs.enqueue(:posted_group_post_created, post_id: post.id)
  end

  on(:post_destroyed) do |post, _opts, _user|
    next unless SiteSetting.posted_group_enabled
    PostedGroup.handle_post_destroyed(post.id)
  end

  on(:post_recovered) do |post, _opts, _user|
    next unless SiteSetting.posted_group_enabled
    Jobs.enqueue(:posted_group_post_recovered, post_id: post.id)
  end

  on(:site_setting_changed) do |name, _old, _new|
    PostedGroup.ensure_groups_exist! if name == :posted_group_thresholds
  end
end
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
