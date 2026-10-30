class ApplicationController < ActionController::API
  # Shared by every controller, so the message names no resource. find on a scope raises this when the row is missing, not numeric, or out of range.
  rescue_from ActiveRecord::RecordNotFound do
    render_error "not_found", "Not found.", :not_found
  end

  # params.expect raises this when a required key is missing or has the wrong shape.
  rescue_from ActionController::ParameterMissing do
    render_error "bad_request", "Request body is malformed.", :bad_request
  end

  private

  # Every error body has the same shape: { "error": { "code": "<snake_case>", "message": "<human text>" } }.
  def render_error(code, message, status)
    render json: { error: { code: code, message: message } }, status: status
  end
end
