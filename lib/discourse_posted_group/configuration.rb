# frozen_string_literal: true

module DiscoursePostedGroup
  module Configuration
    module_function

    MAX_RULES = 5
    GROUP_NAME_PATTERN = /\A[a-zA-Z0-9_.-]+\z/

    def rules
      configured_rules = []

      MAX_RULES.times do |index|
        slot = index + 1

        name =
          SiteSetting
            .public_send("posted_group_#{slot}_name")
            .to_s
            .strip

        threshold =
          SiteSetting
            .public_send("posted_group_#{slot}_threshold")
            .to_i

        next if name.blank?
        next if threshold < 1

        unless valid_group_name?(name)
          Rails.logger.warn(
            "[discourse-posted-group] Ignoring invalid group name " \
            "in slot #{slot}: #{name.inspect}"
          )
          next
        end

        configured_rules << {
          name: name,
          threshold: threshold,
          slot: slot
        }
      end

      duplicate_names =
        configured_rules
          .group_by { |rule| rule[:name].downcase }
          .select { |_name, rules| rules.length > 1 }
          .keys

      duplicate_names.each do |duplicate_name|
        Rails.logger.warn(
          "[discourse-posted-group] Group #{duplicate_name.inspect} " \
          "is configured more than once. The lowest threshold will be used."
        )
      end

      configured_rules
        .sort_by { |rule| [rule[:threshold], rule[:slot]] }
        .uniq { |rule| rule[:name].downcase }
        .sort_by { |rule| [rule[:threshold], rule[:name].downcase] }
    end

    def valid_group_name?(name)
      name.match?(GROUP_NAME_PATTERN)
    end

    def minimum_threshold
      rules.map { |rule| rule[:threshold] }.min
    end
  end
end
