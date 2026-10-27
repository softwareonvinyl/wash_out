module WashOut
  # The WashOut::Dispatcher module should be included in a controller acting
  # as a SOAP endpoint. It includes actions for generating WSDL and handling
  # SOAP requests.
  module Dispatcher
    # A SOAPError exception can be raised to return a correct SOAP error
    # response.
    class SOAPError < Exception
      attr_accessor :code
      def initialize(message, code=nil)
        super(message)
        @code = code
      end
    end

    class ProgrammerError < Exception; end

    def _authenticate_wsse
      username_token = soap_data_at(request.env['wash_out.soap_data'],
        [:envelope, :Envelope], [:header, :Header], [:security, :Security], [:username_token, :UsernameToken])
      username_token = nil unless username_token.is_a?(Hash)

      wsse = WashOut::Wsse.authenticate soap_config, username_token

      # Only expose a token that was checked; without WSSE it is caller-supplied.
      if wsse.required? && username_token.present?
        request.env['WSSE_TOKEN'] = wsse.verified_token
      end
    end

    def _map_soap_parameters
      # Undeclared operation: leave it to _invalid_action.
      return unless action_spec

      data = xml_data
      raise SOAPError.new("Invalid SOAP request", 'Client') unless data.is_a?(Hash)

      self.params = _load_params action_spec[:in],
        _strip_empty_nodes(action_spec[:in], data)
    end

    def _map_soap_headers
      @_soap_headers = xml_header_data
    end

    def _strip_empty_nodes(params, hash)
      hash.keys.each do |key|
        param = params.detect { |a| a.raw_name.to_s == key.to_s }
        next if !(param && hash[key].is_a?(Hash))

        value = hash[key].delete_if do |k, _|
          k.to_s[0] == '@' && !param.map.detect { |a| a.raw_name.to_s == k.to_s }
        end

        if value.length > 0
          hash[key] = _strip_empty_nodes param.map, value
        else
          hash[key] = nil
        end
      end

      hash
    end

    # Creates the final parameter hash based on the request spec and xml_data from the request
    def _load_params(spec, xml_data)
      params = HashWithIndifferentAccess.new
      spec.each do |param|
        key = param.raw_name.to_sym
        if xml_data.has_key? key
          params[param.raw_name] = param.load(xml_data, key)
        end
      end
      params
    end

    # This action generates the WSDL for defined SOAP methods.
    def _generate_wsdl
      @map       = self.class.soap_actions
      @namespace = soap_config.namespace
      @prefix    = soap_config.prefix
      @name      = controller_path
      @endpoint  = WashOut::Router.url(request, @name, soap_config.endpoint_base_url)

      render :template => "wash_out/#{soap_config.wsdl_style}/wsdl", :layout => false,
             :content_type => 'text/xml'
    end

    # Render a SOAP response.
    def _render_soap(result, options)
      @namespace   = soap_config.namespace
      @namespaces  = soap_config.namespaces
      @prefix      = soap_config.prefix
      @operation   = soap_action = request.env['wash_out.soap_action']
      @action_spec = self.class.soap_actions[soap_action]
      return _invalid_action unless @action_spec

      returned_nil = result.nil?
      result = { 'value' => result } unless result.is_a? Hash
      result = HashWithIndifferentAccess.new(result)

      # Keys the :return spec does not declare are not rendered. Say so (names
      # only), since an error the app returns that way reaches the caller as an
      # empty success. (render soap: nil returns nothing; nothing is dropped.)
      undeclared = returned_nil ? [] : result.keys - @action_spec[:out].map { |param| param.raw_name.to_s }
      if undeclared.any? && defined?(Rails) && Rails.logger
        Rails.logger.warn("WashOut: #{self.class.name} #{soap_action} response dropped undeclared keys: #{undeclared.join(', ')}")
      end

      inject = lambda {|data, map|
        result_spec = []
        return result_spec if data.nil?

        map.each_with_index do |param, i|
          result_spec[i] = param.flat_copy

          unless data.is_a?(Hash)
            raise ProgrammerError,
              "SOAP response used #{data.inspect} (which is #{data.class.name}), " +
              "in the context where a Hash with key of '#{param.raw_name}' " +
              "was expected."
          end

          value = data[param.raw_name]

          unless value.nil?
            if param.multiplied && !value.is_a?(Array)
              raise ProgrammerError,
                "SOAP response tried to use '#{value.inspect}' " +
                "(which is of type #{value.class.name}), as the value for " +
                "'#{param.raw_name}' (which expects an Array)."
            end

            # Inline complex structure              {:foo => {bar: ...}}
            if param.struct? && !param.multiplied
              result_spec[i].map = inject.call(value, param.map)

            # Inline array of complex structures    {:foo => [{bar: ...}]}
            elsif param.struct? && param.multiplied
              result_spec[i].map = value.map{|e| inject.call(e, param.map)}

            # Inline scalar                         {:foo => :string}
            else
              result_spec[i].value = param.multiplied ? value.map { |v| _soap_scalar(v, param) } : _soap_scalar(value, param)
            end
          end
        end

        return result_spec
      }

      header = options[:header]
      if header.present?
        header = { 'value' => header } unless header.is_a? Hash
        header = HashWithIndifferentAccess.new(header)
      end

      render :template => "wash_out/#{soap_config.wsdl_style}/response",
             :layout => false,
             :locals => {
               :header => header.present? ? inject.call(header, @action_spec[:header_out])
                                      : nil,
               :result => inject.call(result, @action_spec[:out])
             },
             :content_type => 'text/xml'
    end

    def self.invalid_action_message(soap_action)
      "Cannot find SOAP action mapping for #{soap_action.to_s[0, 200]}"
    end

    # This action is a fallback for all undefined SOAP actions.
    def _invalid_action
      render_soap_error(WashOut::Dispatcher.invalid_action_message(request.env['wash_out.soap_action']), 'Client')
    end

    def _invalid_request
      render_soap_error(request.env['wash_out.request_error'] || "Invalid SOAP request", 'Client')
    end

    def _catch_soap_errors
      yield
    rescue SOAPError => error
      if error.code == 'Client' && defined?(Rails) && Rails.logger
        # wash_out's own Client messages hold element names, never values.
        Rails.logger.info("WashOut: #{self.class.name}##{action_name} answered with a Client fault: #{error.message}")
      end
      render_soap_error(error.message, error.code)
    end

    # Render a SOAP error response.
    #
    # Rails do not support sequental rescue_from handling, that is, rescuing an
    # exception from a rescue_from handler. Hence this function is a public API.
    def render_soap_error(message, code=nil)
      render :template => "wash_out/#{soap_config.wsdl_style}/error", :status => 500,
             :layout => false,
             :locals => { :error_message => message, :error_code => (code || 'Server') },
             :content_type => 'text/xml'
    end

    SoapRequest = Struct.new(:params, :headers)

    def soap_request
      SoapRequest.new(@_params, @_soap_headers)
    end

    def self.included(controller)
      entity = if defined?(Rails::VERSION::MAJOR) && (Rails::VERSION::MAJOR >= 4)
        'action'
      else
        'filter'
      end

      controller.send :"around_#{entity}", :_catch_soap_errors
      controller.send :helper, :wash_out
      controller.send :"before_#{entity}", :_authenticate_wsse,   :if => :soap_action?
      controller.send :"before_#{entity}", :_map_soap_parameters, :if => :soap_action?
      controller.send :"before_#{entity}", :_map_soap_headers, :if => :soap_action?

      if defined?(Rails::VERSION::MAJOR) && (Rails::VERSION::MAJOR >= 5)
        controller.send :"skip_before_#{entity}", :verify_authenticity_token, :raise => false
      else
        controller.send :"skip_before_#{entity}", :verify_authenticity_token
      end
    end

    # Kept for API compatibility; the router uses WashOut::MultiRef.
    # Appends into a single accumulator (no copy per container).
    def self.deep_select(collection, result=[], &blk)
      values = collection.respond_to?(:values) ? collection.values : collection
      values.each { |value| result << value if blk.call(value) }

      values.each do |value|
        if value.is_a?(Hash) || value.is_a?(Array)
          deep_select(value, result, &blk)
        end
      end

      result
    end

    # Kept for API compatibility; delegates to the bounded resolver, which
    # rejects circular references, caps expansion and does not mutate +element+.
    def self.deep_replace_href(element, replace)
      WashOut::MultiRef.replace(element, replace)
    end

    private
    # Builder appends a Symbol argument to the element name and turns a Hash
    # argument into attributes, so scalar values must reach it as plain values.
    def _soap_scalar(value, param)
      if value.is_a?(Hash) || value.is_a?(Array)
        raise ProgrammerError,
          "SOAP response used #{value.class.name} as the value for '#{param.raw_name}', " +
          "which is declared as a simple type."
      end
      value.is_a?(Symbol) ? value.to_s : value
    end

    def soap_action?
      soap_action.present?
    end

    def action_spec
      self.class.soap_actions[soap_action]
    end

    def request_input_tag
      action_spec[:request_tag]
    end

    def soap_action
      request.env['wash_out.soap_action']
    end

    # Follows +path+ (lists of alternative keys) through nested Hashes;
    # nil as soon as a level is missing or is not a Hash.
    def soap_data_at(node, *path)
      path.each do |keys|
        return nil unless node.is_a?(Hash)
        node = node.values_at(*keys).compact.first
      end
      node
    end

    def xml_data
      body = soap_data_at(request.env['wash_out.soap_data'], [:envelope, :Envelope], [:body, :Body]) || {}
      return body if soap_config.wsdl_style == "document"
      return nil unless body.is_a?(Hash)

      # Read the element the router dispatched on, not a look-alike sibling.
      operation = request.env['wash_out.soap_operation']
      return body[operation] || {} if operation

      # Operation from the SOAPAction header: exact names before the
      # snakecase alias.
      body.values_at(request_input_tag.to_sym, soap_action.to_sym, soap_action.underscore.to_sym).compact.first || {}
    end

    def xml_header_data
      header = soap_data_at(request.env['wash_out.soap_data'], [:envelope, :Envelope], [:header, :Header])
      header.is_a?(Hash) ? header : {}
    end

  end
end
