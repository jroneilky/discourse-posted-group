# frozen_string_literal: true

require "rails_helper"

describe Jobs::DiscoursePostedGroupProcessUser do
  fab!(:user) { Fabricate(:user) }

  it "processes the supplied user" do
    expect(
      DiscoursePostedGroup::Processor
    ).to receive(:process_user).with(
      have_attributes(id: user.id)
    )

    described_class.new.execute(user_id: user.id)
  end

  it "does nothing for a nonexistent user" do
    expect(
      DiscoursePostedGroup::Processor
    ).not_to receive(:process_user)

    described_class.new.execute(user_id: -999_999)
  end
end
