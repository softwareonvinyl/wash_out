require 'base64'

module WashOut
  class Param
    attr_accessor :raw_name
    attr_accessor :name
    attr_accessor :map
    attr_accessor :type
    attr_accessor :multiplied
    attr_accessor :value
    attr_accessor :source_class
    attr_accessor :soap_config

    # Value ranges of the XSD types published in the WSDL (:integer is xsd:int).
    XSD_INT_RANGE  = (-(2**31))..(2**31 - 1)
    XSD_LONG_RANGE = (-(2**63))..(2**63 - 1)
    # Longest numeric text accepted, so no conversion works on huge input.
    MAX_NUMBER_LENGTH = 64

    # Simple types Param#load can read.
    LOADABLE_TYPES = %w[string integer long double boolean date datetime time base64Binary].freeze

    # Raised for a value that does not fit its type. Messages name the rule
    # only, never the value, so they are safe to log.
    class InvalidValue < ArgumentError; end

    INTEGER_FORMAT = /\A[+-]?\d+\z/
    DOUBLE_FORMAT  = /\A[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?\z/

    # xsd:int / xsd:long. Rejects anything that is not a whole number in range.
    def self.coerce_integer(value, range)
      if value.is_a?(String)
        text = value.strip
        raise InvalidValue, 'not an integer' unless text.length <= MAX_NUMBER_LENGTH && text.match?(INTEGER_FORMAT)
        value = text.to_i
      end
      raise InvalidValue, 'not an integer' unless value.is_a?(Integer)
      raise InvalidValue, 'integer out of range' unless range.cover?(value)
      value
    end

    # xsd:double. Rejects text that is not a number, and non-finite results.
    def self.coerce_double(value)
      if value.is_a?(String)
        text = value.strip
        raise InvalidValue, 'not a number' unless text.length <= MAX_NUMBER_LENGTH && text.match?(DOUBLE_FORMAT)
        # XSD allows a '.' with no digits after it ("5.", "1.e5"); Kernel#Float does not.
        value = text.sub(/\.(?=[eE]|\z)/, '.0')
      end
      number = Float(value)
      raise InvalidValue, 'not a finite number' unless number.finite?
      number
    end

    # An empty element that carries only attributes (xsi:type, xmlns, ...),
    # which Nori parses as {"@xsi:type" => "xsd:string"}.
    def self.attributes_only?(value)
      value.is_a?(Hash) && !value.empty? && value.each_key.all? { |k| k.to_s.start_with?('@') }
    end

    # What an empty item of a repeated simple value has always loaded as
    # (nil.to_s, nil.to_i, ... in 0b7d787). Apps rely on it, e.g. a blank
    # filter value is "" rather than nil.
    EMPTY_ITEM = { 'string' => ''.freeze, 'integer' => 0, 'long' => 0, 'double' => 0.0, 'boolean' => false }.freeze

    # xsd:boolean: true/1 and false/0 (any case, surrounding whitespace ignored).
    def self.coerce_boolean(value)
      return value if value == true || value == false
      case value.to_s.strip.downcase
      when 'true', '1'  then true
      when 'false', '0' then false
      else raise InvalidValue, 'not a boolean'
      end
    end

    # Defines a WSDL parameter with name +name+ and type specifier +type+.
    # The type specifier format is described in #parse_def.
    def initialize(soap_config, name, type, multiplied = false)
      type ||= {}
      @soap_config = soap_config
      @name       = name.to_s
      @raw_name   = name.to_s
      @map        = {}
      @multiplied = multiplied

      if soap_config.camelize_wsdl.to_s == 'lower'
        @name = @name.camelize(:lower)
      elsif soap_config.camelize_wsdl
        @name = @name.camelize
      end

      if type.is_a?(Symbol)
        @type = type.to_s
      elsif type.is_a?(Class)
        @type         = 'struct'
        @map          = self.class.parse_def(soap_config, type.wash_out_param_map)
        @source_class = type
      else
        @type = 'struct'
        @map  = self.class.parse_def(soap_config, type)
      end
    end

    # Converts a generic externally derived Ruby value, such as String or
    # Hash, to a native Ruby object according to the definition of this type.
    # +path+ names the element in faults and logs, e.g. PO/LineItemArray/LineItem[2]/unitPrice.
    def load(data, key, path = nil)
      if !data.has_key? key
        raise WashOut::Dispatcher::SOAPError, "Required SOAP parameter '#{key}' is missing"
      end

      path = path ? "#{path}/#{key}" : key.to_s
      data = data[key]

      if struct?
        if @multiplied
          # An empty repeated element (<ItemArray/>) is still a fault, as in
          # 0b7d787: apps (PurchaseOrderBuilder) index x[0] without a guard, so
          # accepting it would turn a visible fault into a silent failure.
          items = data.is_a?(Array) ? data : [data]
          items.each_with_index.map do |x, i|
            item_path = "#{path}[#{i + 1}]"
            map_struct(x, item_path) do |param, dat, elem|
              param.load(dat, elem, item_path)
            end
          end
        else
          data ||= {}
          map_struct(data, path) do |param, dat, elem|
            param.load(dat, elem, path)
          end
        end
      else
        operation = case type
          when 'string';       :to_s
          when 'integer';      lambda{|dat| self.class.coerce_integer(dat, XSD_INT_RANGE)}
          when 'long';         lambda{|dat| self.class.coerce_integer(dat, XSD_LONG_RANGE)}
          when 'double';       lambda{|dat| self.class.coerce_double(dat)}
          when 'boolean';      lambda{|dat| self.class.coerce_boolean(dat)}
          when 'date';         :to_date
          when 'datetime';     :to_datetime
          when 'time';         :to_time
          when 'base64Binary'; lambda{|dat| Base64.decode64(dat)}
          else raise RuntimeError, "Invalid WashOut simple type: #{type}"
        end

        data = [data] if @multiplied && !data.is_a?(Array)

        cast = lambda do |dat|
          if dat.nil? || self.class.attributes_only?(dat)
            nil
          elsif dat.is_a?(Hash) || dat.is_a?(Array)
            # Child elements or a repeated element where one value is declared.
            raise InvalidValue, 'not a simple value'
          elsif operation.is_a?(Symbol)
            dat.send(operation)
          else
            operation.call(dat)
          end
        end

        begin
          if data.nil?
            data
          elsif @multiplied
            data.map do |item|
              value = cast.call(item)
              value.nil? ? EMPTY_ITEM[type] : value
            end
          else
            cast.call(data)
          end
        rescue => error
          # The rule broken, never the value (it may be a password).
          reason = error.is_a?(InvalidValue) ? error.message : error.class.name
          if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
            Rails.logger.info("WashOut: invalid SOAP parameter #{path} (#{type}): #{reason}")
          end
          raise WashOut::Dispatcher::SOAPError.new("Invalid SOAP parameter '#{path}' format", 'Client')
        end
      end
    end

    # True if any param in +params+ (recursively) is the attribute @+name+.
    # Simple types in +params+ (recursively) that Param#load cannot read.
    def self.unloadable_types(params)
      params.flat_map do |param|
        if param.struct?
          unloadable_types(param.map)
        else
          LOADABLE_TYPES.include?(param.type.to_s) ? [] : [param.type.to_s]
        end
      end.uniq
    end

    def self.declares_attribute?(params, name)
      params.any? do |param|
        param.raw_name.to_s == "@#{name}" || (param.struct? && declares_attribute?(param.map, name))
      end
    end

    # Checks if this Param defines a complex type.
    def struct?
      type == 'struct'
    end

    def classified?
      !source_class.nil?
    end

    def basic_type
      return name unless classified?
      return source_class.wash_out_param_name(@soap_config)
    end

    def xsd_type
      return 'int' if type.to_s == 'integer'
      return 'dateTime' if type.to_s == 'datetime'
      return type
    end

    # Returns a WSDL namespaced identifier for this type.
    def namespaced_type
      struct? ? "#{@soap_config[:prefix]}:#{basic_type}" : "xsd:#{xsd_type}"
    end

    # Parses a +definition+. The format of the definition is best described
    # by the following BNF-like grammar.
    #
    #   simple_type := :string | :integer | :double | :boolean
    #   nested_type := type_hash | simple_type | WashOut::Param instance
    #   type_hash   := { :parameter_name => nested_type, ... }
    #   definition  := [ WashOut::Param, ... ] |
    #                  type_hash |
    #                  simple_type
    #
    # If a simple type is passed as the +definition+, a single Param is returned
    # with the +name+ set to "value".
    # If a WashOut::Param instance is passed as a +nested_type+, the corresponding
    # +:parameter_name+ is ignored.
    #
    # This function returns an array of WashOut::Param objects.
    def self.parse_def(soap_config, definition)
      raise RuntimeError, "[] should not be used in your params. Use nil if you want to mark empty set." if definition == []
      return [] if definition == nil

      if definition.is_a?(Class) && definition.ancestors.include?(WashOut::Type)
        definition = definition.wash_out_param_map
      end

      if [Array, Symbol].include?(definition.class)
        definition = { :value => definition }
      end

      if definition.is_a? Hash
        definition.map do |name, opt|
          if opt.is_a? WashOut::Param
            opt
          elsif opt.is_a? Array
            WashOut::Param.new(soap_config, name, opt[0], true)
          else
            WashOut::Param.new(soap_config, name, opt)
          end
        end
      else
        raise RuntimeError, "Wrong definition: #{definition.inspect}"
      end
    end

    def flat_copy
      copy = self.class.new(@soap_config, @name, @type.to_sym, @multiplied)
      copy.raw_name = raw_name
      copy.source_class = source_class
      copy
    end

    def attribute?
      name[0] == "@"
    end

    def attr_name
      raise 'Not attribute' unless attribute?
      name[1..-1]
    end

    private

    # Used to load an entire structure.
    def map_struct(data, path = nil)
      unless data.is_a?(Hash)
        where = path ? " at '#{path}'" : ''
        raise WashOut::Dispatcher::SOAPError.new("SOAP message structure is broken#{where}", 'Client')
      end

      data   = data.with_indifferent_access
      struct = {}.with_indifferent_access

      # RUBY18 Enumerable#each_with_object is better, but 1.9 only.
      @map.map do |param|
        if data.has_key? param.raw_name
          param_name = param.attribute? ? param.attr_name : param.raw_name
          struct[param_name] = yield param, data, param.raw_name
        end
      end

      struct
    end
  end
end
