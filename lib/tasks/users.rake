require "io/console"

namespace :users do
  desc "Create the user, or update the password if the username exists. Interactive: needs a terminal."
  task create: :environment do
    # Reads a line with the terminal echo off. The text is never printed or logged.
    read_password = lambda do |prompt|
      $stdout.print prompt
      $stdout.flush
      line = $stdin.noecho { |input| input.gets }
      $stdout.puts
      line.to_s.chomp
    end

    # Never read a password from a pipe or a script: it would be echoed or recorded somewhere.
    abort "users:create needs an interactive terminal (no TTY on stdin). Nothing was changed." unless $stdin.tty?

    $stdout.print "Username: "
    $stdout.flush
    username = $stdin.gets.to_s.strip.downcase
    abort "Username can't be blank. Nothing was changed." if username.empty?

    password = read_password.call("Password: ")
    confirmation = read_password.call("Password again: ")

    abort "The two passwords differ. Nothing was changed." unless password == confirmation
    unless (12..72).cover?(password.bytesize)
      abort "The password must be 12 to 72 bytes long (bcrypt ignores everything past 72). Nothing was changed."
    end

    user = User.find_or_initialize_by(username: username)
    action = user.new_record? ? "created" : "updated"
    user.password = password
    user.save!

    # Later (api-2): delete this user's refresh tokens here, so a password change ends every session.

    puts "User #{user.username} #{action}"
  end
end
