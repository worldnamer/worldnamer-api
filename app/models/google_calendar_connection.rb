# A user's link to their Google account, for reading their calendar. Only Google's refresh token is kept, encrypted at
# rest; access tokens are minted when needed and thrown away.
#
# The status is derived from the row: no row is "not_connected", a row with lost_at set is "lost" (Google rejected the
# token, which has been cleared), any other row is "connected".
class GoogleCalendarConnection < ApplicationRecord
  belongs_to :user

  # Non-deterministic Active Record encryption: the same token encrypts differently each time, so the column cannot be
  # searched, and nothing needs to search it.
  encrypts :refresh_token

  def status
    lost_at ? "lost" : "connected"
  end
end
