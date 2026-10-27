require 'nori'
require 'wash_out/request_parser'
require 'wash_out/multi_ref'

module WashOut
  # This class is a Rack middleware used to route SOAP requests to a proper
  # action of a given SOAP controller.
  #
  # It runs before any controller code, so before the application has
  # authenticated the caller. It therefore:
  #
  # * only runs operations for POST, and never reads other request bodies;
  # * reads at most soap_config.max_request_size bytes;
  # * parses the body once, with the WashOut::RequestParser limits;
  # * resolves multiRef references only for declared operations, with the
  #   WashOut::MultiRef limits;
  # * answers anything that does not name a declared operation with a Client
  #   SOAP fault itself, without running the controller's callbacks (the
  #   app's before_actions would see only query-string parameters), and logs
  #   the rule that was broken, or only the exception class for parser errors
  #   (their messages quote the request body, passwords included).
  class Router
    class RequestTooLarge < StandardError; end

    # Route constraint for the WSDL route: it never reads the request body, so
    # a form-typed body is dropped before Rails logs it in "Parameters:".
    # Always matches.
    DISCARD_FORM_PARAMS = lambda { |request| WashOut::Router.discard_form_params(request.env); true }

    class InvalidEnvelope < StandardError; end

    FAULT_ACTIONS = %w[_invalid_request _invalid_action].freeze

    def self.lookup_soap_routes(controller_name, routes, path=[], &block)
      routes.each do |x|
        defaults = x.defaults
        defaults = defaults[:defaults] if defaults.include?(:defaults) # Rails 5
        if defaults[:controller] == controller_name && defaults[:action] == 'soap'
          yield path+[x]
        end

        app = x.app
        app = app.app if app.respond_to?(:app)
        if app.respond_to?(:routes) && app.routes.respond_to?(:routes)
          lookup_soap_routes(controller_name, app.routes.routes, path+[x], &block)
        end
      end
    end

    class RouteNotFound < StandardError; end

    # Endpoint URL advertised in the WSDL. +base_url+ (soap_config
    # endpoint_base_url) pins the origin; without it the origin comes from the
    # request, i.e. from the Host / X-Forwarded-Host headers the caller sent.
    def self.url(request, controller_name, base_url = nil)
      lookup_soap_routes(controller_name, Rails.application.routes.routes) do |routes|

        path = if routes.first.respond_to?(:optimized_path)      # Rails 4
          routes.map(&:optimized_path)
        elsif routes.first.path.respond_to?(:build_formatter)    # Rails 5
          routes.map{|x| x.path.build_formatter.evaluate(nil)}
        else
          routes.map{|x| x.format({})}                           # Rails 3.2
        end

        if Rails.application.config.relative_url_root.present?
          path.prepend Rails.application.config.relative_url_root
        end
        origin = base_url.present? ? base_url.to_s.chomp('/') : request.protocol + request.host_with_port
        return origin + path.flatten.join('')
      end

      raise RouteNotFound, "WashOut: no wash_out route for #{controller_name}"
    end

    def initialize(controller_name)
      @controller_name = "#{controller_name.to_s}_controller".camelize
    end

    def controller
      @controller
    end

    def parse_soap_action(env)
      return env['wash_out.soap_action'] if env['wash_out.soap_action']

      soap_action = controller.soap_config.soap_action_routing ? env['HTTP_SOAPACTION'].to_s.gsub(/^"(.*)"$/, '\1')
                                                               : ''
      if soap_action.blank?
        operation = self.class.operation_key(parse_soap_body(env))
        return nil if operation.nil?

        # The Dispatcher reads parameters from exactly this element.
        env['wash_out.soap_operation'] = operation
        soap_action = operation.to_s
      end

      soap_action = soap_action.dup.force_encoding('UTF-8')
      return nil unless soap_action.valid_encoding?

      if controller.soap_config.namespace
        namespace = Regexp.escape controller.soap_config.namespace.to_s
        soap_action = soap_action.sub(/\A(#{namespace}(\/|#)?)?([^"]*)\z/, '\3')
      end

      env['wash_out.soap_action'] = soap_action
    end

    # The Body child to dispatch on: the first element, ignoring attributes.
    # nil unless the message has an Envelope with a Body that holds an element.
    def self.operation_key(data)
      return nil unless data.is_a?(Hash)
      envelope = data.values_at(:envelope, :Envelope).compact.first
      return nil unless envelope.is_a?(Hash)
      body = envelope.values_at(:body, :Body).compact.first
      return nil unless body.is_a?(Hash)
      body.keys.find { |key| !key.to_s.start_with?('@') }
    end

    # True when +data+ is an Envelope holding a Body that is empty (<Body/>,
    # e.g. a document operation without arguments) or holds elements, and no
    # Envelope, Header or Body element carries an href (they are never
    # SOAP-encoding accessors, and following one would swap in other content
    # after routing).
    # Why +data+ is not a SOAP envelope the router can dispatch, or nil.
    # +operation+ is the Body key of the rpc operation element, if any.
    def self.envelope_problem(data, operation = nil)
      return 'no SOAP Envelope' unless data.is_a?(Hash)
      envelope = data.values_at(:envelope, :Envelope).compact.first
      return 'no SOAP Envelope' unless envelope.is_a?(Hash)
      # Namespaces are stripped, so a look-alike <header>/<body> would be read
      # instead of the SOAP one. No SOAP client sends both spellings.
      if (envelope.key?(:header) && envelope.key?(:Header)) || (envelope.key?(:body) && envelope.key?(:Body))
        return 'SOAP Header or Body spelled twice'
      end
      return 'no SOAP Body' unless envelope.key?(:body) || envelope.key?(:Body)

      body = envelope.values_at(:body, :Body).compact.first
      return 'SOAP Body holds text or repeats' unless body.nil? || body.is_a?(Hash)

      routed = operation && body && body[operation]
      return 'operation element holds text or repeats' unless routed.nil? || routed.is_a?(Hash)

      headers = Array.wrap(envelope[:header]) + Array.wrap(envelope[:Header])
      # Never SOAP-encoding accessors; following one would swap in other
      # content after routing. Without an rpc operation element (document
      # style) the Body's children are the message parts themselves.
      parts = operation ? [routed] : (body || {}).values.flat_map { |part| Array.wrap(part) }
      if [envelope, *headers, body, *parts].any? { |node| node.is_a?(Hash) && node.key?(:@href) }
        return 'href on the Envelope, Header, Body, operation element or a message part'
      end
      nil
    end

    def self.soap_envelope?(data, operation = nil)
      envelope_problem(data, operation).nil?
    end

    # Nori >= 2.7 dropped the String#snakecase core extension.
    def self.snakecase(tag)
      if defined?(Nori::StringUtils) && Nori::StringUtils.respond_to?(:snakecase)
        Nori::StringUtils.snakecase(tag)
      elsif tag.respond_to?(:snakecase)
        tag.snakecase
      else
        tag.underscore
      end
    end

    def nori(snakecase=false)
      WashOut::RequestParser.new(
        {
          :parser => controller.soap_config.parser,
          :strip_namespaces => true,
          # WashOut::Param#load types every argument itself. Nori's guesses
          # (true/false, dates) would rewrite :string arguments first.
          :advanced_typecasting => false,
          # Reject badly encoded input instead of silently replacing bytes.
          :scrub_xml => false,
          # Nori treats an unprefixed type="..." attribute as an instruction
          # to typecast (integer, decimal, base64Binary, file, array, ...).
          # That is not SOAP; drop it. xsi:type is not affected.
          :convert_attributes_to => lambda { |name, value| name == 'type' ? [] : [name, value] },
          :convert_tags_to => (
            snakecase ? lambda { |tag| WashOut::Router.snakecase(tag).to_sym }
                      : lambda { |tag| tag.to_sym }
          )
        },
        max_depth: controller.soap_config.max_nesting_depth,
        max_elements: controller.soap_config.max_elements
      )
    end

    # Reads the request body, refusing anything over max_request_size.
    def soap_body(env)
      body = env['rack.input']
      return ''.b if body.nil?

      limit  = controller.soap_config.max_request_size
      length = env['CONTENT_LENGTH'].to_s
      raise RequestTooLarge, 'Content-Length over max_request_size' if limit && length =~ /\A\d+\z/ && length.to_i > limit

      body.rewind if body.respond_to? :rewind
      data = limit ? body.read(limit + 1) : body.read
      data ||= ''.b
      raise RequestTooLarge, 'body over max_request_size' if limit && data.bytesize > limit
      data
    ensure
      body.rewind if body.respond_to? :rewind
    end

    # Parses the body once per request; the result is shared through the env.
    def parse_soap_body(env)
      env['wash_out.soap_data'] ||= nori(controller.soap_config.snakecase_input).parse(soap_body(env))
    end

    # Parsed body with multiRef (href/id) references resolved.
    def parse_soap_parameters(env)
      data   = parse_soap_body(env)
      config = controller.soap_config
      # In rpc style the Body holds the operation element plus, for encoded
      # clients, Body-level multiRef elements that are expanded where they
      # are referenced. In document style every Body child is a part.
      extra = if config.wsdl_style.to_s == 'rpc'
        { independent_in: soap_body_element(data),
          keep: env['wash_out.soap_operation'] || self.class.operation_key(data) }
      else
        {}
      end
      env['wash_out.soap_data'] = WashOut::MultiRef.resolve(data,
        max_depth: config.max_nesting_depth,
        max_text: config.max_request_size || WashOut::MultiRef::DEFAULT_MAX_TEXT, **extra)
    end

    # With the operation taken from SOAPAction (rpc), find the element the
    # Dispatcher will read params from, and record it so both agree.
    def bind_operation_element(env, data, soap_action, action_spec)
      return env['wash_out.soap_operation'] if env['wash_out.soap_operation']
      body = soap_body_element(data)
      return nil if body.nil?

      names = [action_spec[:request_tag], soap_action, soap_action.to_s.underscore].compact.map(&:to_sym).uniq
      key = names.find { |name| body.key?(name) }
      if key.nil? && body.keys.any? { |k| !k.to_s.start_with?('@') }
        raise InvalidEnvelope, 'no operation element named after the SOAPAction'
      end
      env['wash_out.soap_operation'] = key
    end

    def soap_body_element(data)
      return nil unless data.is_a?(Hash)
      envelope = data.values_at(:envelope, :Envelope).compact.first
      return nil unless envelope.is_a?(Hash)
      body = envelope.values_at(:body, :Body).compact.first
      body.is_a?(Hash) ? body : nil
    end

    def call(env)
      @controller = @controller_name.constantize

      action = route(env)

      env["action_dispatch.request.content_type"] = Mime[:soap]
      self.class.discard_form_params(env)
      return fault_response(env, action) if FAULT_ACTIONS.include?(action)

      controller.action(action).call(env)
    end

    # The controller's SOAP fault, rendered without dispatching to it.
    def fault_response(env, action)
      message = if action == '_invalid_action'
        WashOut::Dispatcher.invalid_action_message(env['wash_out.soap_action'])
      else
        env['wash_out.request_error'] || 'Invalid SOAP request'
      end

      body = controller.renderer.render(
        template: "wash_out/#{controller.soap_config.wsdl_style}/error",
        layout: false,
        locals: { error_message: message, error_code: 'Client' }
      )
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        reason = action == '_invalid_action' ? 'undeclared operation' : (env['wash_out.fault_reason'] || 'invalid request')
        Rails.logger.info("WashOut: answered #{controller.name} with a Client fault (#{reason})")
      end

      headers = { 'content-type' => 'text/xml; charset=utf-8' }
      headers = Rack::Headers[headers] if defined?(Rack::Headers)
      [500, headers, [body]]
    end

    # Picks the controller action for this request.
    def route(env)
      # SOAP over HTTP is POST. Never run an operation, or read the body, for
      # GET or HEAD (Rails also routes HEAD here).
      return '_invalid_request' unless env['REQUEST_METHOD'] == 'POST'

      soap_action = parse_soap_action(env)
      if soap_action.blank?
        env['wash_out.fault_reason'] = 'no SOAP operation element'
        return '_invalid_request'
      end

      action_spec = controller.soap_actions[soap_action]
      return '_invalid_action' unless action_spec

      data = parse_soap_body(env)
      operation = if controller.soap_config.wsdl_style.to_s == 'rpc'
        bind_operation_element(env, data, soap_action, action_spec)
      end
      problem = self.class.envelope_problem(data, operation)
      raise InvalidEnvelope, problem if problem

      parse_soap_parameters(env)
      action_spec[:to]
    rescue StandardError, SystemStackError => error
      reject_request(env, error)
    end

    # A SOAP body is never form data. Without this, a request sent with a
    # form (or no) Content-Type has its whole envelope, password included,
    # form-parsed by Rack and written to the Rails "Parameters:" log line.
    def self.discard_form_params(env)
      env['action_dispatch.request.request_parameters'] = ActiveSupport::HashWithIndifferentAccess.new
      env.delete('action_dispatch.request.parameters')
      env['rack.request.form_hash']  = {}
      env['rack.request.form_pairs'] = []
      env['rack.request.form_input'] = env['rack.input']
      env.delete('rack.request.form_vars')
      env.delete('rack.request.form_error')
    end

    private

    OWN_ERRORS = [RequestTooLarge, InvalidEnvelope, WashOut::RequestParser::Error, WashOut::MultiRef::Error].freeze

    def reject_request(env, error)
      # Make sure the wash_out callbacks skip a half-parsed request.
      env.delete('wash_out.soap_action')
      env.delete('wash_out.soap_data')
      env.delete('wash_out.soap_operation')
      env['wash_out.request_error'] = error.is_a?(RequestTooLarge) ? 'Request body too large' : 'Invalid SOAP request'

      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        # wash_out's own errors carry fixed messages; parser messages
        # (REXML::ParseException and friends) quote the body, so only the
        # class is logged for those.
        detail = OWN_ERRORS.any? { |klass| error.is_a?(klass) } ? ": #{error.message}" : ''
        Rails.logger.warn("WashOut: rejected SOAP request (#{error.class.name}#{detail})")
      end
      '_invalid_request'
    end
  end
end
