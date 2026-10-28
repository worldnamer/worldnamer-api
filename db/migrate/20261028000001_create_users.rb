class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      # Login is by username, not email (see login-plan.md): there is no email column.
      # Devise stores usernames downcased and stripped, so a plain unique index is case-insensitive.
      t.string :username, null: false
      t.string :encrypted_password, null: false, default: ""

      t.timestamps
    end

    add_index :users, :username, unique: true
  end
end
