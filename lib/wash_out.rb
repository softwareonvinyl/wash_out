require 'wash_out/configurable'
require 'wash_out/soap_config'
require 'wash_out/soap'
require 'wash_out/engine'
require 'wash_out/param'
require 'wash_out/dispatcher'
require 'wash_out/soap'
require 'wash_out/request_parser'
require 'wash_out/multi_ref'
require 'wash_out/router'
require 'wash_out/type'
require 'wash_out/model'
require 'wash_out/wsse'
require 'wash_out/middleware'

module WashOut
  def self.root
    File.expand_path '../..', __FILE__
  end
end

module ActionDispatch::Routing
  class Mapper
    # Adds the routes for a SOAP endpoint at +controller+.
    def wash_out(controller_name, options={})
      if options.any?
        # Options apply to these two routes only. As in 0b7d787 they replace
        # the enclosing scope's values (module: 'space' inside namespace :route
        # means Space::), but in a child frame that is dropped afterwards; they
        # used to be written into the enclosing frame and leaked into every
        # route drawn after them.
        @scope = @scope.new(options.to_h.symbolize_keys)
        begin
          return wash_out(controller_name)
        ensure
          @scope = @scope.parent
        end
      end

      # Scope#[] reads through enclosing scopes (module: 'a' inside namespace :b => "b/a").
      controller_class_name = [@scope && @scope[:module], controller_name].compact.join("/").underscore

      match "#{controller_name}/wsdl"   => "#{controller_name}#_generate_wsdl", :via => :get, :format => false,
        :constraints => WashOut::Router::DISCARD_FORM_PARAMS,
        :as => "#{controller_class_name}_wsdl"
      match "#{controller_name}/action" => WashOut::Router.new(controller_class_name), :via => [:get, :post],
        :defaults => { :controller => controller_class_name, :action => 'soap' }, :format => false,
        :as => "#{controller_class_name}_soap"
    end
  end
end

Mime::Type.register "application/soap+xml", :soap
# Use the load hook rather than touching ActiveRecord::Base here: loading it
# while the app boots runs Active Record's own on_load hooks early (for example
# the one that copies config.filter_parameters into filter_attributes).
ActiveSupport.on_load(:active_record) { extend WashOut::Model }

ActionController::Renderers.add :soap do |what, options|
  _render_soap(what, options)
end

ActionController::Metal.class_eval do

  # Define a SOAP service. The function has no required +options+:
  # but allow any of :parser, :namespace, :wsdl_style, :snakecase_input,
  # :camelize_wsdl, :wsse_username, :wsse_password and :catch_xml_errors.
  #
  # Any of the the params provided allows for overriding the defaults
  # (like supporting multiple namespaces instead of application wide such)
  #
  def self.soap_service(options={})
    include WashOut::SOAP
    self.soap_config = options
  end
end

if Rails::VERSION::MAJOR >= 5
  if defined?(ActionView::Rendering)
    module ActionController
      module ApiRendering
        include ActionView::Rendering
      end
    end
  end

  ActiveSupport.on_load :action_controller do
    if self == ActionController::API
      include ActionController::Helpers
    end
  end
end
