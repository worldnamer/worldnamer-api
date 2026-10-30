class User < ApplicationRecord
  # database_authenticatable: bcrypt hashing and valid_password?.
  # jwt_authenticatable: verifies the access JWT (devise-jwt). The Null strategy keeps no denylist on purpose:
  # access tokens are revoked by their 15 minute lifetime (see specs/login-plan.md, section 2).
  devise :database_authenticatable, :jwt_authenticatable, jwt_revocation_strategy: Devise::JWT::RevocationStrategies::Null

  # One row per refresh token. delete_all because the rows have no callbacks, and the database cascades as well.
  has_many :refresh_tokens, dependent: :delete_all

  # Habits have no callbacks either; the foreign key cascades in the database as well. Completions hang off a habit,
  # so a deleted user's completions go through that cascade too.
  has_many :habits, dependent: :delete_all

  # Lists have no callbacks either; the foreign key cascades in the database as well.
  has_many :task_lists, dependent: :delete_all

  # Devise lowercases and strips :username (case_insensitive_keys / strip_whitespace_keys in config/initializers/devise.rb)
  # before validation, so a plain uniqueness check is case-insensitive.
  validates :username, presence: true, uniqueness: true
end
