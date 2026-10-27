require 'spec_helper'
require 'open3'
require 'json'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'

# `require "wash_out"` runs during Bundler.require, before any initializer.
# 0b7d787 touched ActiveRecord::Base there, which ran Active Record's load
# hooks early: filter_parameters added in config/initializers never reached
# ActiveRecord::Base.filter_attributes (record #inspect, SQL bind logging).
# This needs a fresh process, because this one has already loaded wash_out.
describe "require 'wash_out' and the Active Record boot order" do
  CHILD_APP = <<~'RUBY'
    ENV["RAILS_ENV"] = "production"
    ENV["SECRET_KEY_BASE"] ||= "x" * 64
    require "rails"
    require "active_record/railtie"
    require "action_controller/railtie"

    require "wash_out"
    ar_loaded_by_require = (ActiveSupport.instance_variable_get(:@loaded)[:active_record] || []).any?

    # Never connect to a database.
    ActiveRecord::ConnectionAdapters.register("specnull", "ActiveRecord::ConnectionAdapters::AbstractAdapter",
                                              "active_record/connection_adapters/abstract_adapter")
    class BootOrderApp < Rails::Application
      config.load_defaults 8.1
      config.root = ENV.fetch("BOOT_APP_ROOT")
      config.eager_load = false
      config.logger = ActiveSupport::Logger.new(nil)
      config.filter_parameters << :password
    end
    BootOrderApp.initialize!

    puts JSON.dump(
      ar_loaded_by_require: ar_loaded_by_require,
      filter_attributes: ActiveRecord::Base.filter_attributes.map(&:to_s),
      model_extended: ActiveRecord::Base.singleton_class.include?(WashOut::Model)
    )
  RUBY

  before(:all) do
    root = Dir.mktmpdir("wash_out_boot")
    begin
      FileUtils.mkdir_p(File.join(root, "config/initializers"))
      File.write(File.join(root, "config/database.yml"), "production:\n  adapter: specnull\n")
      File.write(File.join(root, "config/initializers/filter_parameter_logging.rb"),
                 "Rails.application.config.filter_parameters += [:token, :secret]\n")

      lib = File.expand_path("../../../lib", __dir__)
      out, err, status = Open3.capture3({ "BOOT_APP_ROOT" => root }, RbConfig.ruby, "-W0", "-I", lib, "-e", CHILD_APP)
      raise "child boot failed:\n#{err}" unless status.success?
      @boot = JSON.parse(out.lines.last)
    ensure
      FileUtils.remove_entry(root)
    end
  end

  it 'does not load ActiveRecord::Base at require time' do
    expect(@boot['ar_loaded_by_require']).to be false
  end

  it 'lets filter_parameters from config/initializers reach filter_attributes' do
    expect(@boot['filter_attributes']).to include('password', 'token', 'secret')
  end

  it 'still extends ActiveRecord::Base with WashOut::Model' do
    expect(@boot['model_extended']).to be true
  end
end
