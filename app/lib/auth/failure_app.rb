module Auth
  # Devise's default failure app answers with {"error": "..."} or a redirect. This one answers with our error shape
  # (see ../CLAUDE.md, Error shape) for any request Warden rejects, e.g. GET /api/v1/me without a valid token.
  class FailureApp < Devise::FailureApp
    def respond
      self.status = 401
      self.content_type = "application/json"
      self.response_body = { error: { code: "unauthenticated", message: "Authentication required." } }.to_json
    end
  end
end
