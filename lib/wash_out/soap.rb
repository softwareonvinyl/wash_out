require 'active_support/concern'

module WashOut
  module SOAP
    extend ActiveSupport::Concern

    # Public wash_out methods that are not controller actions. Rails would
    # otherwise list them in action_methods. The routes never reach them, and
    # this keeps it that way however an app draws its routes.
    NON_ACTION_METHODS = %w[
      soap_config soap_config= _authenticate_wsse _map_soap_parameters
      _map_soap_headers _strip_empty_nodes _load_params _render_soap
      _catch_soap_errors render_soap_error soap_request wsse_username
    ].freeze

    module ClassMethods
      attr_writer :soap_actions

      # A subclass starts from a copy of its parent's operations.
      def soap_actions
        @soap_actions ||= superclass.respond_to?(:soap_actions) ? superclass.soap_actions.dup : {}
      end

      # Inherited operations hold Params built against the parent's config,
      # whose prefix or camelize_wsdl this class may have changed.
      def _wash_out_rebind_soap_actions
        return if soap_actions.empty?
        config = soap_config
        self.soap_actions = soap_actions.transform_values do |spec|
          params = spec[:in] + spec[:out] + Array(spec[:header_out])
          next spec if params.all? { |param| param.soap_config.equal?(config) }
          spec.merge(
            :in         => WashOut::Param.parse_def(config, spec[:args]),
            :out        => WashOut::Param.parse_def(config, spec[:return]),
            :header_out => spec[:header_return].present? ? WashOut::Param.parse_def(config, spec[:header_return]) : nil
          )
        end
      end

      def action_methods
        @_wash_out_action_methods ||= (super - NON_ACTION_METHODS).freeze
      end

      def clear_action_methods!
        @_wash_out_action_methods = nil
        super
      end

      # Define a SOAP action +action+. The function has two required +options+:
      # :args and :return. Each is a type +definition+ of format described in
      # WashOut::Param#parse_def.
      #
      # An optional option :to can be passed to allow for names of SOAP actions
      # which are not valid Ruby function names.
      # There is also an optional :header_return option to specify the format of the
      # SOAP response's header tag (<env:Header></env:Header>). If unspecified, there will
      # be no header tag in the response.
      def soap_action(action, options={})
        if options[:as].present?
          options[:to] ||= action
          action = options[:as]
        end

        if action.is_a?(Symbol)
          if soap_config.camelize_wsdl.to_s == 'lower'
            options[:to] ||= action.to_s
            action         = action.to_s.camelize(:lower)
          elsif soap_config.camelize_wsdl
            options[:to] ||= action.to_s
            action         = action.to_s.camelize
          end

        end

        default_response_tag = soap_config.camelize_wsdl ? 'Response' : '_response'
        default_response_tag = action+default_response_tag


        in_params = WashOut::Param.parse_def(soap_config, options[:args])
        unloadable = WashOut::Param.unloadable_types(in_params)
        if unloadable.any?
          # Every request would fail before reaching the app.
          raise ArgumentError, "SOAP action #{action}: argument types #{unloadable.join(', ')} cannot be read from requests " \
                               "(use one of #{WashOut::Param::LOADABLE_TYPES.join(', ')})"
        end
        if WashOut::Param.declares_attribute?(in_params, 'type')
          # The router drops every plain type="..." attribute from requests
          # (Nori would otherwise typecast by it), so it could never arrive.
          raise ArgumentError, "SOAP action #{action}: an argument attribute named @type is not supported"
        end

        self.soap_actions[action] = options.merge(
          :in           => in_params,
          :request_tag  => options[:as] || action,
          :out          => WashOut::Param.parse_def(soap_config, options[:return]),
          :header_out   => options[:header_return].present? ? WashOut::Param.parse_def(soap_config, options[:header_return]) : nil,
          :to           => options[:to] || action,
          :response_tag => options[:response_tag] || default_response_tag,
          :namespace_everything => options[:namespace_everything] || false
        )
      end
    end

    included do
      include WashOut::Configurable
      include WashOut::Dispatcher
      include WashOut::WsseParams
      self.soap_actions = {}
    end
  end
end
