# name: discourse-posted-group
# about: Automatically adds users to the "posted" group once they've made at least one post or reply
# version: 1.4
# authors: jronielky
# frozen_string_literal: true

enabled_site_setting :posted_group_enabled

require_relative "lib/discourse_posted_group/configuration"
require_relative "lib/discourse_posted_group/processor"

after_initialize do
  DiscourseEvent.on(:post_created) do |post, _opts, user|
    begin
      next unless SiteSetting.posted_group_enabled?
      next if post.blank?
      next if user.blank?
      next if user.bot?
      next unless post.post_type == Post.types[:regular]
      next if post.topic.blank?

      unless SiteSetting.posted_group_count_private_messages?
        next if post.topic.archetype == Archetype.private_message
      end

      Jobs.enqueue(
        :discourse_posted_group_process_user,
        user_id: user.id
      )
    rescue StandardError => e
      Rails.logger.error(
        "[discourse-posted-group] Event handler failed for " \
        "post #{post&.id.inspect}: #{e.full_message}"
      )
    end
  end
end
