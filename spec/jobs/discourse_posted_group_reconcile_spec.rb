# frozen_string_literal: true

require "rails_helper"

describe Jobs::DiscoursePostedGroupReconcile do
  fab!(:user) { Fabricate(:user) }
  fab!(:topic) { Fabricate(:topic) }
  fab!(:posted_group) { Fabricate(:group, name: "posted") }

  before do
    SiteSetting.posted_group_enabled = true
    SiteSetting.posted_group_reconciliation_enabled = true
    SiteSetting.posted_group_reconciliation_interval_hours = 24
    SiteSetting.posted_group_reconciliation_batch_size = 500

    SiteSetting.posted_group_1_name = "posted"
    SiteSetting.posted_group_1_threshold = 1
  end

  after do
    PluginStore.destroy("discourse-posted-group")
  end

  it "repairs a missed event" do
    Fabricate(
      :post,
      user: user,
      topic: topic,
      post_type: Post.types[:regular],
      deleted_at: nil,
      hidden: false
    )

    described_class.new.execute({})

    expect(
      posted_group.group_users.where(user_id: user.id).count
    ).to eq(1)
  end

  it "does not run again before the configured interval" do
    PluginStore.set(
      "discourse-posted-group",
      "last_reconciliation_at",
      Time.zone.now.to_i
    )

    expect(
      DiscoursePostedGroup::Processor
    ).not_to receive(:process_user)

    described_class.new.execute({})
  end
end
