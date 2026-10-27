module WashOut
  # Per-controller SOAP configuration.
  #
  # Each controller class owns its config. A subclass reads its parent's config
  # until it calls soap_service itself; it then gets its own copy, so it never
  # changes the parent's settings.
  module Configurable
    extend ActiveSupport::Concern

    included do
      class_attribute :_wash_out_soap_config, instance_accessor: false,
                      default: WashOut::SoapConfig.new({}).freeze
    end

    module ClassMethods
      def soap_config
        _wash_out_soap_config
      end

      def soap_config=(obj)
        unless obj.is_a?(Hash)
          raise "Value needs to be a Hash."
        end

        # Every call builds (and validates) a new, frozen config from the
        # current one, so no class ever changes a config another class reads,
        # and a rejected config changes nothing.
        self._wash_out_soap_config = WashOut::SoapConfig.new(_wash_out_soap_config.config.merge(obj)).freeze
        _wash_out_rebind_soap_actions if respond_to?(:_wash_out_rebind_soap_actions, true)
      end
    end

    def soap_config
      self.class.soap_config
    end
  end
end
