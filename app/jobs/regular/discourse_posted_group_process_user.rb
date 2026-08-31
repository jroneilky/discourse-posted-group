# frozen_string_literal: true

module Jobs
  class DiscoursePostedGroupProcessUser < ::Jobs::Base
    def execute(args)
      user_id = args[:user_id] || args["user_id"]
      return if user_id.blank?

      user = User.find_by(id: user_id)
      return if user.blank?

      DiscoursePostedGroup::Processor.process_user(user)
    rescue StandardError => e
      Rails.logger.error(
        "[discourse-posted-group] User-processing job failed for " \
        "user #{user_id.inspect}: #{e.full_message}"
      )
      false
    end
  end
end
