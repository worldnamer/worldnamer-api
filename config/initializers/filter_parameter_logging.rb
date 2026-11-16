# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # Google's OAuth callback: the one-time authorization code and the state (this also covers code_verifier).
  :code, :state,
  # A video's transcript text, stored in transcripts.lines: it is third-party content and could be long, so it stays
  # out of the SQL a debug-level log shows.
  :lines,
  # A video's summary, stored in summaries.summary_text: model output that could be long and has no use in the log, so
  # it stays out of the SQL a debug-level log shows.
  :summary_text
]
