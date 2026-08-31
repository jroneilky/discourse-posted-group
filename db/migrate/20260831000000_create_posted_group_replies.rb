# db/migrate/20260831000000_create_posted_group_replies.rb
# frozen_string_literal: true

class CreatePostedGroupReplies < ActiveRecord::Migration[7.0]
  def up
    unless table_exists?(:posted_group_replies)
      create_table :posted_group_replies, id: false do |t|
        t.bigint :post_id, null: false
        t.bigint :user_id, null: false
      end
    end

    unless index_exists?(:posted_group_replies, :post_id, unique: true)
      add_index :posted_group_replies, :post_id, unique: true
    end

    unless index_exists?(:posted_group_replies, :user_id)
      add_index :posted_group_replies, :user_id
    end

    execute <<~SQL
      INSERT INTO posted_group_replies (post_id, user_id)
      SELECT p.id, p.user_id
      FROM posts p
      INNER JOIN topics t ON t.id = p.topic_id
      INNER JOIN users u ON u.id = p.user_id
      WHERE p.post_type = 1
        AND p.post_number > 1
        AND p.user_id > 0
        AND p.deleted_at IS NULL
        AND t.deleted_at IS NULL
        AND t.archetype = 'regular'
        AND u.staged = false
      ON CONFLICT (post_id) DO NOTHING
    SQL
  end

  def down
    drop_table :posted_group_replies if table_exists?(:posted_group_replies)
  end
end
# db/migrate/20260831000000_create_posted_group_replies.rb
# frozen_string_literal: true

class CreatePostedGroupReplies < ActiveRecord::Migration[7.0]
  def up
    create_table :posted_group_replies, id: false do |t|
      t.bigint :post_id, null: false
      t.bigint :user_id, null: false
    end
    add_index :posted_group_replies, :post_id, unique: true
    add_index :posted_group_replies, :user_id

    # post_type 1 == :regular. user_id > 0 excludes system/bot users.
    execute <<~SQL
      INSERT INTO posted_group_replies (post_id, user_id)
      SELECT p.id, p.user_id
      FROM posts p
      INNER JOIN topics t ON t.id = p.topic_id
      INNER JOIN users u ON u.id = p.user_id
      WHERE p.post_type = 1
        AND p.post_number > 1
        AND p.user_id > 0
        AND p.deleted_at IS NULL
        AND t.deleted_at IS NULL
        AND t.archetype = 'regular'
        AND u.staged = false
      ON CONFLICT (post_id) DO NOTHING
    SQL
  end

  def down
    drop_table :posted_group_replies
  end
end
