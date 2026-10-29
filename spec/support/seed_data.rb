# db:prepare seeds a fresh test database (CI does this), which leaves john in it. Specs create their own
# users, so start the suite with none. Cascading foreign keys remove any refresh tokens.
RSpec.configure do |config|
  config.before(:suite) { User.delete_all }
end
