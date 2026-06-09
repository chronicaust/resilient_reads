module ResilientReads
  # Rack middleware that automatically wraps GET/HEAD requests in a
  # distribute_reads context.  Respects the "read your own write"
  # delay: after a mutating request, subsequent reads stay on primary
  # for +primary_delay+ seconds.
  class Middleware
    WRITE_METHODS = %w[POST PUT PATCH DELETE].freeze
    COOKIE_NAME   = "_resilient_reads_last_write".freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) unless ResilientReads.config.by_default
      return @app.call(env) if ResilientReads.replica_pool.empty?

      request = Rack::Request.new(env)

      if write_request?(request)
        status, headers, body = @app.call(env)
        set_last_write_cookie(headers)
        [ status, headers, body ]
      elsif recent_write?(request)
        # Within the primary_delay window — skip replica routing.
        @app.call(env)
      else
        ResilientReads.run { @app.call(env) }
      end
    end

    private

    def write_request?(request)
      WRITE_METHODS.include?(request.request_method)
    end

    def recent_write?(request)
      cookie = request.cookies[COOKIE_NAME]
      return false unless cookie

      last_write = cookie.to_f
      (Time.now.to_f - last_write) < ResilientReads.config.primary_delay
    rescue
      false
    end

    def set_last_write_cookie(headers)
      Rack::Utils.set_cookie_header!(
        headers,
        COOKIE_NAME,
        value: Time.now.to_f.to_s,
        path: "/",
        httponly: true,
        same_site: :lax
      )
    end
  end
end
