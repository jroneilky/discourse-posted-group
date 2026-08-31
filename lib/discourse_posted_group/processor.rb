# frozen_string_literal: true

module DiscoursePostedGroup
  module Processor
    module_function

    def process_user(user)
      return false unless SiteSetting.posted_group_enabled?
      return false if user.blank?
      return false if user.bot?
      return false if user.id.to_i <= 0

      configured_rules = Configuration.rules
      return false if configured_rules.empty?

      count = qualifying_post_count(user.id)
      return false if count.zero?

      eligible_rules =
        configured_rules.select do |rule|
          count >= rule[:threshold]
        end

      return false if eligible_rules.empty?

      groups =
        find_groups(eligible_rules.map { |rule| rule[:name] })

      eligible_rules.each do |rule|
        group = groups[rule[:name].downcase]

        unless group
          Rails.logger.error(
            "[discourse-posted-group] Configured group does not exist: " \
            "#{rule[:name].inspect}"
          )
          next
        end

        if group.respond_to?(:automatic?) && group.automatic?
          Rails.logger.error(
            "[discourse-posted-group] Refusing to modify automatic group: " \
            "#{group.name.inspect}"
          )
          next
        end

        add_user_to_group(group, user)
      end

      true
    end

    def qualifying_post_count(user_id)
      scope =
        Post
          .where(user_id: user_id)
          .where(post_type: Post.types[:regular])
          .joins(:topic)

      if SiteSetting.posted_group_count_deleted_posts?
        scope = scope.with_deleted
      else
        scope = scope.where(posts: { deleted_at: nil })
      end

      unless SiteSetting.posted_group_count_private_messages?
        scope =
          scope.where.not(
            topics: { archetype: Archetype.private_message }
          )
      end

      unless SiteSetting.posted_group_count_hidden_posts?
        scope = scope.where(posts: { hidden: false })
      end

      scope.count
    end

    def find_groups(names)
      normalized_names = names.map { |name| name.downcase }.uniq

      return {} if normalized_names.empty?

      Group
        .where("LOWER(name) IN (?)", normalized_names)
        .index_by { |group| group.name.downcase }
    end

    def add_user_to_group(group, user)
      group.add(user, automatic: true)
      true
    rescue ActiveRecord::RecordNotUnique
      true
    rescue StandardError => e
      Rails.logger.error(
        "[discourse-posted-group] Failed adding user #{user.id} to " \
        "group #{group.name.inspect}: #{e.full_message}"
      )
      false
    end
  end
end
