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

  # Stores a fresh connection for the user, replacing any earlier one (connected or lost) in one upsert on user_id.
  # The new connected_at is what lets a status check still in flight on the old token see that it must not mark this
  # one lost.
  def self.connect!(user_id:, refresh_token:)
    upsert({ user_id: user_id, refresh_token: refresh_token, connected_at: Time.current, lost_at: nil }, unique_by: :user_id)
  end

  def status
    lost_at ? "lost" : "connected"
  end

  # Asks Google whether the stored refresh token still works and returns the status that results. This is a blocking
  # call to Google (a few seconds at worst) on the request's thread.
  #
  # - Accepted: "connected". The access token is thrown away; a new refresh token, if Google sends one, is stored.
  # - Rejected (invalid_grant: revoked in Google, or expired): the connection is marked lost.
  # - Anything else (timeout, 5xx, invalid_client): Google's answer says nothing about this user's token, so the stored
  #   status stands and nothing changes.
  #
  # A lost connection is not checked again: there is no token left to check.
  def check(client: GoogleCalendar::OauthClient.new)
    return status if lost_at

    mint_access_token(client: client)
    "connected"
  rescue GoogleCalendar::OauthClient::InvalidGrant
    # If the user reconnected while the check was running, mark_lost! leaves the new connection alone.
    mark_lost! ? "lost" : reload.status
  rescue GoogleCalendar::OauthClient::Error
    status
  end

  # Swaps the stored refresh token for a new access token and returns it, a blocking call to Google. The access token
  # is for this request only: the caller uses it and drops it, and it is never stored, cached or logged. A new refresh
  # token, if Google sends one, is stored (encrypted) unless the user has reconnected in the meantime.
  #
  # Raises GoogleCalendar::OauthClient::InvalidGrant when Google no longer accepts the stored token (the caller
  # decides whether to mark_lost!), and GoogleCalendar::OauthClient::Error for anything else.
  def mint_access_token(client: GoogleCalendar::OauthClient.new)
    tokens = client.refresh_access_token(refresh_token)
    store_rotated_refresh_token(tokens.refresh_token) if tokens.refresh_token
    tokens.access_token
  end

  # Clears the token and sets lost_at, in ONE conditional statement:
  # UPDATE ... WHERE id = ? AND connected_at = ?. A reconnect between loading this row and calling this method sets a
  # new connected_at, so the statement matches nothing and the fresh connection survives. Returns true if it marked
  # the row.
  def mark_lost!
    now = Time.current
    marked = self.class.where(id: id, connected_at: connected_at)
      .update_all(refresh_token: nil, lost_at: now, updated_at: now) == 1
    if marked
      self.refresh_token = nil
      self.lost_at = now
      clear_changes_information
    end
    marked
  end

  private

  # Same condition as mark_lost!, so a token from the old grant never overwrites a newer connection. update_all
  # encrypts the value like a normal save does.
  def store_rotated_refresh_token(new_token)
    self.class.where(id: id, connected_at: connected_at)
      .update_all(refresh_token: new_token, updated_at: Time.current)
  end
end
