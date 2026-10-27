require 'active_support/security_utils'
require 'base64'
require 'digest/sha1'
require 'time'

module WashOut

  module WsseParams
    # Username of a UsernameToken that WSSE verified. nil when the service
    # does not use WSSE (wash_out never exposes an unchecked token).
    def wsse_username
      if request.env['WSSE_TOKEN']
        request.env['WSSE_TOKEN'].values_at(:username, :Username).compact.first
      end
    end
  end

  class Wsse
    # How far a token's Created time may be from the server clock, either way.
    TIMESTAMP_WINDOW = 5 * 60

    attr_reader :soap_config

    # The UsernameToken fields WSSE reads, in either spelling.
    TOKEN_FIELDS = { username: [:username, :Username], password: [:password, :Password],
                     nonce: [:nonce, :Nonce], created: [:created, :Created] }.freeze

    # Raises SOAPError unless the token is acceptable. Returns the Wsse.
    def self.authenticate(soap_config, token)
      wsse = self.new(soap_config, token)

      unless wsse.eligible?
        raise WashOut::Dispatcher::SOAPError.new("Unauthorized", 'Client')
      end
      wsse
    end

    def initialize(soap_config, token)
      @soap_config = soap_config
      if token.blank? && required?
        raise WashOut::Dispatcher::SOAPError.new("Missing required UsernameToken", 'Client')
      end
      @username_token = token
    end

    # WSSE is on as soon as any wsse_* option is set, so a password configured
    # without a username fails closed instead of switching checks off.
    def required?
      [soap_config.wsse_username, soap_config.wsse_password].any?(&:present?) ||
        !soap_config.wsse_auth_callback.nil?
    end

    # The token fields that were checked, for request.env['WSSE_TOKEN'], under
    # the caller's own spelling (Username or username). Nonce and Created are
    # included only when a digest or the callback used them; anything else in
    # the UsernameToken is left out.
    def verified_token
      return nil unless @username_token.is_a?(Hash)
      names = @verified_fields || []
      TOKEN_FIELDS.each_with_object(ActiveSupport::HashWithIndifferentAccess.new) do |(name, keys), out|
        next unless names.include?(name)
        key = keys.find { |k| @username_token.key?(k) }
        value = token_value(name)
        out[key] = value unless key.nil? || value.nil? || value == :ambiguous
      end
    end

    def auth_callback?
      callback = soap_config.wsse_auth_callback
      return false if callback.nil?
      # Fail closed: a callback that cannot be called must not switch WSSE off.
      unless callback.respond_to?(:call) && callback.arity == 4
        raise ArgumentError, "wsse_auth_callback must be callable with (user, password, nonce, timestamp)"
      end
      true
    end

    def perform_auth_callback(user, password, nonce, timestamp)
      soap_config.wsse_auth_callback.call(user, password, nonce, timestamp)
    end

    def expected_user
      soap_config.wsse_username
    end

    def expected_password
      soap_config.wsse_password
    end

    def eligible?
      return true unless required?
      return false unless @username_token.is_a?(Hash)

      user      = token_value(:username)
      password  = token_value(:password)
      nonce     = token_value(:nonce)
      timestamp = token_value(:created)
      return false unless user.is_a?(String) && password.is_a?(String)
      return false unless [nonce, timestamp].all? { |v| v.nil? || v.is_a?(String) }

      # A username without a password configured never matches.
      credentials = expected_user.present? && expected_password.present?

      if credentials && self.class.secure_equal?(expected_user, user) &&
         self.class.matches_expected_digest?(expected_password, password, nonce, timestamp)
        @verified_fields = [:username, :password, :nonce, :created]
        return true
      end

      if auth_callback?
        @verified_fields = [:username, :password, :nonce, :created]
        return perform_auth_callback(user, password, nonce, timestamp)
      end

      @verified_fields = [:username, :password]
      credentials &&
        self.class.secure_equal?(expected_user, user) &&
        self.class.secure_equal?(expected_password, password)
    end

    # PasswordDigest = Base64(SHA1(nonce + created + password)), computed over
    # the Created text exactly as sent. Created must be within
    # TIMESTAMP_WINDOW of now, in the past or the future.
    #
    # There is no nonce cache: a captured digest stays valid for the window.
    def self.matches_expected_digest?(expected_password, password, nonce, timestamp)
      return false unless [expected_password, password, nonce].all? { |v| v.is_a?(String) }
      return false if expected_password.empty?

      created = parse_created(timestamp)
      return false if created.nil?
      return false if (Time.now.utc - created).abs > TIMESTAMP_WINDOW

      created_texts = if timestamp.is_a?(String)
        [timestamp]
      else
        [created.strftime("%Y-%m-%dT%H:%M:%SZ"), created.strftime("%Y-%m-%dT%H:%M:%S.%3NZ")]
      end

      raw_nonce = Base64.decode64(nonce)
      created_texts.any? do |text|
        # There are a few different implementations of the digest calculation
        flavors = [
          # Ruby / Savon: Base64 nonce as sent, hex digest
          Base64.encode64(Digest::SHA1.hexdigest(nonce.b + text.b + expected_password.b)).chomp,
          # Java / SoapUI: decoded nonce, binary digest
          Base64.encode64(Digest::SHA1.digest(raw_nonce.b + text.b + expected_password.b)).chomp
        ]
        flavors.any? { |f| secure_equal?(f, password) }
      end
    end

    def self.parse_created(timestamp)
      case timestamp
      when String then Time.iso8601(timestamp.strip).utc
      when Time, DateTime then timestamp.to_time.utc
      end
    rescue ArgumentError
      nil
    end

    def self.secure_equal?(expected, given)
      expected.is_a?(String) && given.is_a?(String) &&
        ActiveSupport::SecurityUtils.secure_compare(expected.to_s, given.to_s)
    end

    private

    # :ambiguous when the token carries both spellings of a field, so the
    # caller cannot get one checked and another read later.
    def token_value(name)
      present = TOKEN_FIELDS.fetch(name).select { |key| @username_token.key?(key) }
      return :ambiguous if present.size > 1
      present.empty? ? nil : @username_token[present.first]
    end
  end
end
