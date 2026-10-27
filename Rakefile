require 'bundler/setup'
require 'bundler/gem_tasks'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new

begin
  require 'appraisal'
rescue LoadError
  # Appraisal is optional: `rake` runs the suite against the Gemfile's Rails.
end

task :console do
  require "action_controller/railtie"
  require "rails/test_unit/railtie"
  Bundler.require
  binding.pry
end


desc 'Default: run the specs.'
task default: [:spec]

desc 'Test the plugin under all Appraisal Rails versions (needs the appraisal gem).'
task :all do |_t|
    # this is needed for minitest because it does not support "--pattern" option as Rspec Does
    ENV['SPEC'] = '--name=spec/**{,/*/**}/*_spec.rb'
    exec('bundle exec appraisal install && bundle exec rake appraisal spec')
end
