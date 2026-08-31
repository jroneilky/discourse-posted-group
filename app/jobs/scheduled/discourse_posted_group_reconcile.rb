# frozen_string_literal: true

module Jobs
  class DiscoursePostedGroupReconcile < ::Jobs::Scheduled
    every 1.hour

    PLUGIN_STORE_NAMESPACE = "discourse-posted-group"
    LAST_RUN_KEY = "last_reconciliation_at"

    def execute(_args)
      return unless SiteSetting.posted_group_enabled?
      return unless SiteSetting.posted_group_reconciliation_enabled?
      return unless should_run?

      rules = DiscoursePostedGroup::Configuration.rules
      return if rules.empty?

      minimum_threshold =
        DiscoursePostedGroup::Configuration.minimum_threshold

      return if minimum_threshold.blank?

      batch_size =
        SiteSetting.posted_group_reconciliation_batch_size.to_i

      batch_size = 500 if batch_size < 50

      candidate_user_ids(minimum_threshold).find_in_batches(
        batch_size: batch_size
      ) do |user_ids|
        user_ids.each do |user_id|
          user = User.find_by(id: user_id)
          next if user.blank?
          next if user.bot?
          next if user.id.to_i <= 0

          begin
            DiscoursePostedGroup::Processor.process_user(user)
          rescue StandardError => e
            Rails.logger.error(
              "[discourse-posted-group] Reconciliation failed for " \
              "user #{user.id}: #{e.full_message}"
            )
          end
        end
      end

      mark_completed
    rescue StandardError => e
      Rails.logger.error(
        "[discourse-posted-group] Reconciliation job failed: " \
        "#{e.full_message}"
      )
      false
    end

    private

    def candidate_user_ids(minimum_threshold)
      UserStat
        .where("post_count >= ?", minimum_threshold)
        .order(:user_id)
        .pluck(:user_id)
    end

    def should_run?
      raw_timestamp =
        ::PluginStore.get(
          PLUGIN_STORE_NAMESPACE,
          LAST_RUN_KEY
        )

      return true if raw_timestamp.blank?

      timestamp = Integer(raw_timestamp, 10)
      interval =
        SiteSetting.posted_group_reconciliation_interval_hours.to_i.hours

      Time.zone.at(timestamp) <= interval.ago
    rescue ArgumentError, TypeError, StandardError
      Rails.logger.warn(
        "[discourse-posted-group] Invalid reconciliation timestamp " \
        "#{raw_timestamp.inspect}; running reconciliation."
      )
      true
    end

    def mark_completed
      ::PluginStore.set(
        PLUGIN_STORE_NAMESPACE,
        LAST_RUN_KEY,
        Time.zone.now.to_i
      )
    end
  end
end
