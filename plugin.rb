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
  require_dependency "jobs/base" 
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
