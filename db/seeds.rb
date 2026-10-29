# Creates the known development user so a story can log in without a terminal (users:create needs a TTY).
# bin/rails db:seed runs this; db:setup and db:prepare run it too on a fresh database.

# The password below is public (it is in the web mock), so production must never get this user. This guard
# comes first and returns before the database is touched.
if Rails.env.production?
  puts "Skipped db/seeds.rb: the seed user is for development and test only."
  return
end

# An existing john is left completely alone: his password may be one the developer chose.
unless User.find_by(username: "john")
  User.create!(username: "john", password: "correct horse battery")
  puts "Seeded user john"
end
