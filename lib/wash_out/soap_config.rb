# frozen_string_literal: true

module WashOut
  require 'forwardable'
  require 'uri'
  # Configuration options for {Client}, defaulting to values
  # in {Default}
  class SoapConfig
    extend Forwardable
    DEFAULT_CONFIG = {
      parser: :rexml,
      namespace: 'urn:WashOut',
      namespaces: [].freeze,
      wsdl_style: 'rpc',
      snakecase_input: false,
      camelize_wsdl: false,
      catch_xml_errors: false,
      wsse_username: nil,
      wsse_password: nil,
      wsse_auth_callback: nil,
      soap_action_routing: true,
      prefix: 'tns',
      # Request limits, enforced by WashOut::Router before any controller code.
      # Bodies larger than this (in bytes) get a Client fault; nil disables it.
      max_request_size: 1_048_576,
      # Maximum element nesting in a request, also bounding multiRef expansion.
      # At most MAX_NESTING_DEPTH_LIMIT.
      max_nesting_depth: 100,
      # Maximum elements plus attributes in a request (bounds parse memory).
      max_elements: 100_000,
      # Origin advertised in the WSDL soap:address, e.g. "https://api.example.com".
      # When nil it is taken from the request (Host / X-Forwarded-Host).
      endpoint_base_url: nil
    }.freeze

    WSDL_STYLES = %w[rpc document].freeze
    # Nori converts the parsed tree recursively (one Ruby frame per element
    # level), which overflows a Puma thread's stack a little past 300 levels.
    MAX_NESTING_DEPTH_LIMIT = 200
    PARSERS     = %w[rexml nokogiri].freeze
    # Prefixes the templates bind themselves (or that XML reserves).
    RESERVED_PREFIXES = %w[soap soap-enc xsd xsi wsdl].freeze
    # XML NCName (ASCII subset): a namespace prefix or a local name.
    NCNAME = /\A[A-Za-z_][A-Za-z0-9_.\-]*\z/

    def_delegators :@config, :[], :sort

    # A read-only copy: change settings through soap_service / configure.
    def config
      @config.dup.freeze
    end

    # The keys allowed
    def self.keys
      @keys ||= config.keys
    end

    def self.config
      DEFAULT_CONFIG
    end

    def self.soap_accessor(*syms)

      syms.each do |sym|

        unless sym =~ /^[_A-Za-z]\w*$/
          raise NameError.new("invalid class attribute name: #{sym}")
        end
        class_eval(<<-EOS, __FILE__, __LINE__ + 1)
          unless defined? @#{sym}
            @#{sym} = nil
          end

          def #{sym}
            @#{sym}
          end

          def #{sym}=(obj)
            configure(#{sym}: obj)
          end
        EOS
      end
    end

    soap_accessor(*WashOut::SoapConfig.keys)

    def initialize(options = {})
      @config = {}
      # Precedence: options, then app-wide config.wash_out, then defaults.
      # The caller's Hash is not modified.
      merged = DEFAULT_CONFIG.dup
      merged.merge!(engine_config.to_h.symbolize_keys) if engine_config
      merged.merge!(options.to_h.symbolize_keys)
      configure merged
    end

    def default?
      DEFAULT_CONFIG.sort == config.sort
    end

    # soap_service freezes the config it builds; change it with soap_service.
    def freeze
      return self if frozen?
      # Deep enough that String values cannot be changed in place either.
      @config.transform_values! { |value| value.is_a?(String) ? -value : value }
      @config.each { |key, value| instance_variable_set("@#{key}", value) }
      @config.freeze
      super
    end

    def configure(options = {})
      raise FrozenError.new("can't modify a frozen #{self.class.name}; use soap_service", receiver: self) if frozen?
      options = validate_config!(options.to_h.symbolize_keys)
      @config.merge! options

      @config.each do |key, value|
        instance_variable_set("@#{key}", value)
      end
    end

    # Goes through the same validation as configure.
    def []=(key, value)
      configure(key => value)
    end

    private

      def engine_config
        @engine_config ||= WashOut::Engine.config.wash_out
      end

      def validate_config!(options = {})
        rejected_keys = options.keys.reject do |key|
          WashOut::SoapConfig.keys.include?(key)
        end

        if rejected_keys.any?
          raise "The following keys are not allows: #{rejected_keys}\n Did you intend for one of the following? #{WashOut::SoapConfig.keys}"
        end

        validate_values!(options)
        options
      end

      # These values end up in element names, namespace declarations and
      # template paths, so they must be well-formed.
      def validate_values!(options)
        if options.key?(:prefix)
          prefix = options[:prefix].to_s
          if !prefix.match?(NCNAME) || reserved_prefix?(prefix)
            raise ArgumentError, "wash_out prefix must be an XML name the templates do not bind themselves, got #{options[:prefix].inspect}"
          end
        end

        if options.key?(:wsdl_style)
          options[:wsdl_style] = options[:wsdl_style].to_s
          unless WSDL_STYLES.include?(options[:wsdl_style])
            raise ArgumentError, "wash_out wsdl_style must be one of #{WSDL_STYLES.join(', ')}"
          end
        end

        if options.key?(:parser)
          unless PARSERS.include?(options[:parser].to_s)
            raise ArgumentError, "wash_out parser must be one of #{PARSERS.join(', ')}"
          end
          options[:parser] = options[:parser].to_sym
        end

        if options.key?(:namespaces)
          namespaces = options[:namespaces]
          valid = namespaces.is_a?(Array) && namespaces.all? do |ns|
            ns.is_a?(Hash) && ns.keys.all? { |k| k.to_s.match?(/\Axmlns:[A-Za-z_][A-Za-z0-9_.\-]*\z/) }
          end
          raise ArgumentError, "wash_out namespaces must be an Array of {'xmlns:prefix' => uri} Hashes" unless valid
          # String keys, so they merge with the templates' own declarations.
          options[:namespaces] = namespaces.map { |ns| ns.to_h { |k, v| [-k.to_s, v.is_a?(String) ? -v : v] }.freeze }.freeze
        end

        # Checked against the effective pair, so a later prefix change cannot
        # collide with namespaces stored earlier.
        if options.key?(:prefix) || options.key?(:namespaces)
          prefix = options.fetch(:prefix, @prefix).to_s
          names  = Array(options.fetch(:namespaces, @namespaces)).flat_map { |ns| ns.keys.map { |k| k.to_s.delete_prefix('xmlns:') } }
          clash  = names.select { |n| reserved_prefix?(n) || n == 'tns' || n == prefix } +
                   names.group_by(&:itself).select { |_, v| v.size > 1 }.keys
          if clash.any?
            raise ArgumentError, "wash_out namespaces must not bind the service prefix, tns, a prefix the templates bind, " \
                                 "or one prefix twice: #{clash.uniq.join(', ')}"
          end
        end

        [:max_request_size, :max_nesting_depth, :max_elements].each do |key|
          next unless options.key?(key)
          value = options[key]
          next if value.nil? && key == :max_request_size
          raise ArgumentError, "wash_out #{key} must be a positive Integer" unless value.is_a?(Integer) && value > 0
        end
        if options.key?(:max_nesting_depth) && options[:max_nesting_depth] > MAX_NESTING_DEPTH_LIMIT
          raise ArgumentError, "wash_out max_nesting_depth must be at most #{MAX_NESTING_DEPTH_LIMIT}"
        end

        if options.key?(:endpoint_base_url)
          options[:endpoint_base_url] = normalize_base_url(options[:endpoint_base_url])
        end
      end

      def reserved_prefix?(name)
        RESERVED_PREFIXES.include?(name) || name.downcase.start_with?('xml')
      end

      def normalize_base_url(value)
        return nil if value.blank?
        uri = URI.parse(value.to_s)
        # An origin only: the route path (and relative_url_root) is appended.
        unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil? && uri.query.nil? &&
               uri.fragment.nil? && ['', '/'].include?(uri.path)
          raise ArgumentError, "wash_out endpoint_base_url must be an http(s) origin such as https://api.example.com"
        end
        value.to_s.chomp('/')
      rescue URI::InvalidURIError
        raise ArgumentError, "wash_out endpoint_base_url is not a valid URL"
      end
  end
end
