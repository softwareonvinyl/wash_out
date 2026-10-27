require 'builder'
require 'rexml/parseexception'

# Kept so apps that set config.wash_out.catch_xml_errors keep booting; it no
# longer changes anything.
#
# It used to turn REXML::ParseException into a 400 Client fault. WashOut::Router
# now answers every request it cannot parse with a Client fault itself, so a
# REXML error that reaches this middleware comes from server code (an action
# parsing some other XML). Answering that as a client error would hide a
# server bug from error reporting, so it is left to propagate.
class WashOut::Middleware
  def initialize app
    @app = app
  end

  def call env
    @app.call env
  end

  def self.raise_or_render_rexml_parse_error e, env
    raise e
  end

  def self.request_size env
    length = env['CONTENT_LENGTH'].to_s
    return length.to_i if length =~ /\A\d+\z/
    input = env['rack.input']
    input.respond_to?(:size) ? input.size : 0
  end

  def self.render_client_soap_fault msg
    xml = Builder::XmlMarkup.new
    xml.tag! 'soap:Envelope', 'xmlns:soap' => 'http://schemas.xmlsoap.org/soap/envelope/',
      'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance' do
        xml.tag! 'soap:Body' do
          xml.tag! 'soap:Fault', :encodingStyle => 'http://schemas.xmlsoap.org/soap/encoding/' do
            xml.faultcode 'Client'
            xml.faultstring msg
          end
        end
      end
  end
end
