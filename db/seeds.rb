# Creates the known development user so a story can log in without a terminal (users:create needs a TTY).
# bin/rails db:seed runs this; db:setup and db:prepare run it too on a fresh database.

# The password below is public (it is in the web mock), so only development may get this user. An allow-list,
# not a production check: test, staging, a mistyped name and production all skip. It returns before the
# database is touched.
return puts("Skipped db/seeds.rb: the seed user is for development only.") unless Rails.env.development?

# An existing john is left completely alone: his password may be one the developer chose.
unless User.find_by(username: "john")
  User.create!(username: "john", password: "correct horse battery")
  puts "Seeded user john"
end

# Habits can't be added from the site until the add-habit story, so john gets a few to try the list on. Only when he has
# none: habits he added himself are never touched, and running this again adds nothing.
john = User.find_by!(username: "john")
unless john.habits.exists?
  [ "Drink water", "Read 20 pages", "Stretch" ].each { |name| john.habits.create!(name: name) }
  puts "Seeded 3 habits for john"
end
