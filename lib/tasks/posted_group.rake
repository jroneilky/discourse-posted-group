# lib/tasks/posted_group.rake
# frozen_string_literal: true

desc "Backfill group membership for users who already qualify based on existing reply counts"
task "posted_group:backfill_groups" => :environment do
  PostedGroup.thresholds.sort_by { |threshold, _| -threshold }.each do |threshold, group_name|
    group = Group.find_by(name: group_name)
    next if group.blank?

    user_ids = DB.query_single(<<~SQL, threshold: threshold)
      SELECT user_id FROM posted_group_replies
      GROUP BY user_id
      HAVING COUNT(*) >= :threshold
    SQL

    already_in = GroupUser.where(group_id: group.id, user_id: user_ids).pluck(:user_id)
    to_add = user_ids - already_in

    to_add.each do |uid|
      user = User.find_by(id: uid)
      next if user.blank? || user.bot? || user.staged?
      group.add(user)
      putc "."
    rescue ActiveRecord::RecordNotUnique
      next
    end

    puts "\n#{group_name}: added #{to_add.size} users"
  end
end
