# frozen_string_literal: true

require "rails_helper"

describe DiscoursePostedGroup::Processor do
  fab!(:user) { Fabricate(:user) }
  fab!(:topic) { Fabricate(:topic) }
  fab!(:posted_group) { Fabricate(:group, name: "posted") }
  fab!(:posted_10_group) { Fabricate(:group, name: "posted_10") }

  before do
    SiteSetting.posted_group_enabled = true
    SiteSetting.posted_group_count_private_messages = false
    SiteSetting.posted_group_count_deleted_posts = false
    SiteSetting.posted_group_count_hidden_posts = false

    SiteSetting.posted_group_1_name = "posted"
    SiteSetting.posted_group_1_threshold = 1
    SiteSetting.posted_group_2_name = "posted_10"
    SiteSetting.posted_group_2_threshold = 10

    SiteSetting.posted_group_3_name = ""
    SiteSetting.posted_group_4_name = ""
    SiteSetting.posted_group_5_name = ""
  end

  def create_regular_post(
    post_user: user,
    post_topic: topic,
    deleted_at: nil,
    hidden: false
  )
    Fabricate(
      :post,
      user: post_user,
      topic: post_topic,
      post_type: Post.types[:regular],
      deleted_at: deleted_at,
      hidden: hidden
    )
  end

  it "adds the first group after one qualifying post" do
    create_regular_post

    expect do
      described_class.process_user(user)
    end.to change {
      posted_group.group_users.where(user_id: user.id).count
    }.from(0).to(1)
  end

  it "adds the ten-post group at ten qualifying posts" do
    10.times { create_regular_post }

    described_class.process_user(user)

    expect(
      posted_10_group.group_users.where(user_id: user.id).count
    ).to eq(1)
  end

  it "does not add the ten-post group before the threshold" do
    9.times { create_regular_post }

    described_class.process_user(user)

    expect(
      posted_10_group.group_users.where(user_id: user.id)
    ).to be_empty
  end

  it "is safe to run repeatedly" do
    create_regular_post

    3.times { described_class.process_user(user) }

    expect(
      posted_group.group_users.where(user_id: user.id).count
    ).to eq(1)
  end

  it "does not count private-message posts by default" do
    pm_topic =
      Fabricate(
        :topic,
        archetype: Archetype.private_message
      )

    create_regular_post(post_topic: pm_topic)

    described_class.process_user(user)

    expect(
      posted_group.group_users.where(user_id: user.id)
    ).to be_empty
  end

  it "does not count deleted posts by default" do
    create_regular_post(deleted_at: Time.zone.now)

    described_class.process_user(user)

    expect(
      posted_group.group_users.where(user_id: user.id)
    ).to be_empty
  end

  it "does not count hidden posts by default" do
    create_regular_post(hidden: true)

    described_class.process_user(user)

    expect(
      posted_group.group_users.where(user_id: user.id)
    ).to be_empty
  end

  it "supports counting private messages when enabled" do
    SiteSetting.posted_group_count_private_messages = true

    pm_topic =
      Fabricate(
        :topic,
        archetype: Archetype.private_message
      )

    create_regular_post(post_topic: pm_topic)

    described_class.process_user(user)

    expect(
      posted_group.group_users.where(user_id: user.id).count
    ).to eq(1)
  end

  it "supports counting deleted posts when enabled" do
    SiteSetting.posted_group_count_deleted_posts = true

    create_regular_post(deleted_at: Time.zone.now)

    described_class.process_user(user)

    expect(
      posted_group.group_users.where(user_id: user.id).count
    ).to eq(1)
  end

  it "supports arbitrary configured thresholds" do
    contributor_group =
      Fabricate(:group, name: "regular_contributor")

    SiteSetting.posted_group_3_name = "regular_contributor"
    SiteSetting.posted_group_3_threshold = 3

    3.times { create_regular_post }

    described_class.process_user(user)

    expect(
      contributor_group.group_users.where(user_id: user.id).count
    ).to eq(1)
  end

  it "ignores automatic groups" do
    posted_group.update!(automatic: true)
    create_regular_post

    described_class.process_user(user)

    expect(
      posted_group.group_users.where(user_id: user.id)
    ).to be_empty
  end

  it "ignores invalid group names" do
    SiteSetting.posted_group_1_name = "invalid group name"

    expect(described_class.rules).to be_empty
  end
end
