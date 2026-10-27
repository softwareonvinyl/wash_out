require File.expand_path("../lib/wash_out/version", __FILE__)

Gem::Specification.new do |s|
  s.name        = "wash_out"
  s.version     = WashOut::VERSION
  s.platform    = Gem::Platform::RUBY
  s.summary     = "Dead simple Rails 3 SOAP server library"
  s.email       = "boris@roundlake.ru"
  s.homepage    = "http://github.com/inossidabile/wash_out/"
  s.description = "Dead simple Rails 3 SOAP server library"
  s.authors     = ['Boris Staal', 'Peter Zotov']

  s.files         = `git ls-files`.split("\n")
  s.require_paths = ["lib"]
  s.post_install_message = <<-EOS
    Please replace `include WashOut::SOAP` with `soap_service`
    in your controllers if you are upgrading from a version before 0.8.5.
  EOS
  s.required_ruby_version = ">= 3.0"

  # nori < 2.0.3 has the typecasting RCE (CVE-2013-0285). 2.7.0 is the first
  # release that accepts the :scrub_xml option the router passes; older ones
  # refuse every request. WashOut::RequestParser builds on nori 2.x internals,
  # hence the upper bound.
  s.add_dependency("nori", ">= 2.7", "< 3")
  # Default request parser. 3.4.2 fixes the last of the 2024-2025 REXML DoS
  # advisories on the pull-parser path (CVE-2024-35176 ... CVE-2025-58767).
  s.add_dependency("rexml", ">= 3.4.2")
  s.add_dependency("builder", ">= 3.1", "< 4")
  s.add_dependency("actionpack", ">= 7.1")
  s.add_dependency("railties", ">= 7.1")
  s.add_dependency("base64")
end
