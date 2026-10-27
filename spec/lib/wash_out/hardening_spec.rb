require 'spec_helper'

# Regression specs for the security review of the sov fork (revision 0b7d787).
#
# Every example sends one small request through the whole Rails stack
# (in process, Rack::MockRequest) to a controller configured like the
# production PromoStandards services, and checks that a safeguard holds:
# the request is refused with a SOAP fault before the operation runs, or a
# value reaches the operation unchanged.
describe 'WashOut request hardening' do
  SERVICE_NS = 'http://www.promostandards.org/WSDL/Test/1.0.0/'

  # Operations record what they received here.
  def calls
    $wash_out_hardening_calls
  end

  before do
    $wash_out_hardening_calls = []

    mock_controller(
      snakecase_input: false, camelize_wsdl: false, namespace: SERVICE_NS,
      prefix: 'ns1', soap_action_routing: false, wsdl_style: 'rpc'
    ) do
      soap_action 'GetThingRequest',
        namespace_everything: true, skip_blanks: true, skip_xsi_types: true,
        args: {
          id: :string, password: :string, qty: :integer, big: :long,
          price: :double, rush: :boolean, ids: [:integer], item: { sku: :string },
          tags: [:string], lines: [{ desc: :string, qty: :integer }]
        },
        return: { echo: :string },
        to: 'get_thing', response_tag: 'GetThingResponse'

      def get_thing
        $wash_out_hardening_calls << {
          method: request.request_method,
          params: params.to_unsafe_h,
          request_parameters: request.request_parameters.to_h
        }
        render soap: { echo: params[:id].to_s }
      end
    end
  end

  def envelope(inner, op: 'GetThingRequest', head: '')
    <<-XML
<?xml version="1.0" encoding="UTF-8"?>
#{head}<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns="#{SERVICE_NS}">
  <soapenv:Header/>
  <soapenv:Body>
    <ns:#{op}>#{inner}</ns:#{op}>
  </soapenv:Body>
</soapenv:Envelope>
    XML
  end

  # Returns [status, body]. An exception escaping the stack fails the example.
  def soap_post(xml, method: 'POST', content_type: 'text/xml; charset=utf-8')
    opts = { method: method, input: xml }
    opts['CONTENT_TYPE'] = content_type if content_type
    env = Rack::MockRequest.env_for('/route/api/action', opts)
    status, _headers, body = Dummy::Application.call(env)
    text = +''
    body.each { |chunk| text << chunk }
    body.close if body.respond_to?(:close)
    [status, text]
  end

  def params_for_xml(xml)
    status, body = soap_post(xml)
    expect(status).to eq(200), "expected the operation to run, got #{status}: #{body[0, 300]}"
    calls.last[:params]
  end

  def params_for(inner)
    status, body = soap_post(envelope(inner))
    expect(status).to eq(200), "expected the operation to run, got #{status}: #{body[0, 300]}"
    calls.last[:params]
  end

  def expect_client_fault(xml, **opts)
    status, body = soap_post(xml, **opts)
    expect(status).to eq 500
    expect(body).to include('soap:Fault')
    expect(calls).to be_empty
    body
  end

  # Captures what Rails and the router log during the block.
  def capture_logs
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    old_rails, old_controller = Rails.logger, ActionController::Base.logger
    Rails.logger = ActionController::Base.logger = logger
    yield
    io.string
  ensure
    Rails.logger = old_rails
    ActionController::Base.logger = old_controller
  end

  it 'still runs a normal request' do
    params = params_for('<id>acme</id><password>pw</password><qty>3</qty><price>2.50</price><rush>true</rush><ids>1</ids><ids>2</ids>')
    expect(params).to include('id' => 'acme', 'qty' => 3, 'price' => 2.5, 'rush' => true, 'ids' => [1, 2])
  end

  describe 'multiRef (href/id) resolution' do
    it 'still resolves a plain reference' do
      params = params_for('<item href="#i1"/><extra id="i1"><sku>s1</sku></extra>')
      expect(params['item']).to eq('sku' => 's1')
    end

    it 'refuses a self-referencing element' do
      expect_client_fault(envelope('<item id="a" href="#a"/>'))
    end

    it 'refuses mutually referencing elements' do
      expect_client_fault(envelope('<item id="a" href="#b"/><id id="b" href="#a"/>'))
    end

    it 'refuses an href that points at no element' do
      expect_client_fault(envelope('<item href="#missing"/>'))
    end

    it 'caps the work done for shared references' do
      # 16 levels that each reference the next one twice.
      levels = (0...16).map { |i| %(<l#{i} id="l#{i}"><a href="#l#{i + 1}"/><b href="#l#{i + 1}"/></l#{i}>) }
      expect_client_fault(envelope('<item href="#l0"/>' + levels.join + '<l16 id="l16"><v>x</v></l16>'))
    end
  end

  describe 'multiRef edge cases' do
    it 'resolves a reference to a text-only element (Axis soapenc:string style)' do
      expect(params_for('<id href="#s0"/><extra id="s0">acme</extra>')['id']).to eq 'acme'
    end

    it 'refuses an href on the Body element' do
      xml = envelope('<id>x</id>').sub('<soapenv:Body>', '<soapenv:Body href="#b">') + ''
      expect_client_fault(xml.sub('</soapenv:Header>', '').sub('<soapenv:Header/>', '<soapenv:Header><b id="b"/></soapenv:Header>'))
    end

    it 'caps text reached through references' do
      # 300 references to one 4,000-byte text: 1.2 MB handed on from a ~10 KB body,
      # over max(max_request_size, 8 x the text sent).
      long = 'x' * 4_000
      log = capture_logs do
        expect_client_fault(envelope('<id>x</id>' + ('<tags href="#t"/>' * 300) + %(<extra id="t">#{long}</extra>)))
      end
      expect(log).to include('SOAP multiRef text limit exceeded')
    end

    it 'still accepts many references to a shared object (rpc/encoded reuse)' do
      config = 'c' * 2_500
      xml = envelope('<id>x</id>' + ('<lines><desc href="#cfg"/><qty>1</qty></lines>' * 40) + %(<extra id="cfg">#{config}</extra>))
      expect(params_for_xml(xml)['lines'].size).to eq 40
    end

    it 'refuses an href on the routed operation element' do
      xml = envelope('<id>x</id>').sub('<ns:GetThingRequest>', '<ns:GetThingRequest href="#o">').sub('<soapenv:Header/>', '<soapenv:Header><o id="o"><id>other</id></o></soapenv:Header>')
      expect_client_fault(xml)
    end

    it 'refuses an Envelope that spells Header or Body twice' do
      expect_client_fault(envelope('<id>x</id>').sub('<soapenv:Header/>', '<soapenv:Header/><x:header xmlns:x="urn:x"/>'))
    end

    it 'logs which envelope rule a refusal broke' do
      log = capture_logs { expect_client_fault(envelope('just text')) }
      expect(log).to include('InvalidEnvelope: operation element holds text or repeats')
    end

    it 'refuses an href on either of two Header elements' do
      xml = envelope('<id>x</id>').sub('<soapenv:Header/>', '<soapenv:Header/><soapenv:Header href="#h"/>')
      expect_client_fault(xml)
    end

    it 'does not count repeated elements as extra nesting' do
      # 60 element levels, every level repeated: within max_nesting_depth (100).
      inner = (1..60).reduce('x') { |acc, _| "<l>#{acc}</l><l/>" }
      expect(soap_post(envelope("<id>ok</id><deep>#{inner}</deep>")).first).to eq 200
    end
  end

  describe 'empty and attribute-only elements' do
    it 'reads an attribute-only element inside repeated structs as empty' do
      params = params_for('<lines><desc xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="xsd:string"/><qty>1</qty></lines><lines><desc>d</desc><qty>2</qty></lines>')
      expect(params['lines']).to eq [{ 'desc' => nil, 'qty' => 1 }, { 'desc' => 'd', 'qty' => 2 }]
    end

    it 'keeps blank items of a repeated simple value as empty strings' do
      tags = params_for('<tags>a</tags><tags/>')['tags']
      expect(tags).to eq ['a', '']
      expect(tags.last).to be_frozen # as nil.to_s was; one shared object must not be changed
      expect(params_for('<tags>a</tags><tags xmlns="urn:x"/>')['tags']).to eq ['a', '']
    end

    # Kept as in 0b7d787: the app's PurchaseOrderBuilder indexes these arrays
    # without a guard, so accepting them would turn a fault into a silent,
    # rolled-back empty success.
    it 'still answers an empty repeated struct element with a fault naming it' do
      body = expect_client_fault(envelope('<id>x</id><lines/>'))
      expect(body).to include("SOAP message structure is broken at 'lines[1]'")
    end

    it 'names the failing element path in the fault, and logs the rule' do
      log = capture_logs do
        body = expect_client_fault(envelope('<lines><desc>a</desc><qty>1</qty></lines><lines><desc>b</desc><qty>x</qty></lines>'))
        expect(body).to include("Invalid SOAP parameter 'lines[2]/qty' format")
      end
      expect(log).to include('invalid SOAP parameter lines[2]/qty (integer): not an integer')
      expect(log).to include("answered with a Client fault: Invalid SOAP parameter 'lines[2]/qty' format")
    end
  end

  describe 'Nori type attributes' do
    it 'ignores type="base64Binary" on a string argument' do
      expect(params_for('<id type="base64Binary">YWJj</id>')['id']).to eq 'YWJj'
    end

    it 'ignores type="file" on a string argument' do
      expect(params_for('<id type="file">YWJj</id>')['id']).to eq 'YWJj'
    end

    it 'ignores type="date" instead of raising' do
      expect(params_for('<id type="date">not-a-date</id>')['id']).to eq 'not-a-date'
    end

    it 'does not let type="decimal" turn an exponent into an integer' do
      expect_client_fault(envelope('<qty type="decimal">1e5</qty>'))
    end
  end

  describe 'numeric arguments' do
    it 'refuses an integer longer than the type allows' do
      expect_client_fault(envelope("<qty>#{'9' * 40}</qty>"))
    end

    it 'refuses an :integer outside xsd:int' do
      expect_client_fault(envelope('<qty>2147483648</qty>'))
    end

    it 'accepts the largest xsd:long' do
      expect(params_for('<big>9223372036854775807</big>')['big']).to eq 9223372036854775807
    end

    it 'refuses an over-long element of an [:integer] array' do
      expect_client_fault(envelope("<ids>1</ids><ids>#{'9' * 40}</ids>"))
    end

    it 'refuses text that is not an integer' do
      expect_client_fault(envelope('<qty>12abc</qty>'))
    end

    it 'refuses a non-finite double' do
      expect_client_fault(envelope('<price>1e400</price>'))
    end

    it 'accepts XSD doubles with a bare decimal point' do
      expect(params_for('<price>5.</price>')['price']).to eq 5.0
      expect(params_for('<price>1.e5</price>')['price']).to eq 100000.0
      expect(params_for('<price> 2.5 </price>')['price']).to eq 2.5
    end

    it 'refuses text that is not a double' do
      expect_client_fault(envelope('<price>1,000.50</price>'))
    end
  end

  describe 'boolean arguments' do
    it 'reads False as false' do
      expect(params_for('<rush>False</rush>')['rush']).to eq false
    end

    it 'reads 0 and 1' do
      expect(params_for('<rush>0</rush>')['rush']).to eq false
      expect(params_for('<rush>1</rush>')['rush']).to eq true
    end

    it 'refuses anything else' do
      expect_client_fault(envelope('<rush>maybe</rush>'))
    end
  end

  describe 'string arguments' do
    it 'keeps date-like text verbatim' do
      expect(params_for('<id>2024-01-01T10:00:00Z</id>')['id']).to eq '2024-01-01T10:00:00Z'
    end

    it 'refuses child elements where a simple value is declared' do
      expect_client_fault(envelope('<id><a>x</a></id>'))
    end

    it 'refuses a repeated element where one value is declared' do
      expect_client_fault(envelope('<id>a</id><id>b</id>'))
    end

    it 'still decodes predefined entities' do
      expect(params_for('<id>a&amp;b&lt;c</id>')['id']).to eq 'a&b<c'
    end
  end

  describe 'XML characters' do
    it 'refuses a NUL character reference in an attribute value' do
      expect_client_fault(envelope('<id a="x&#0;">y</id>'))
    end

    it 'refuses a C0 control character inside CDATA' do
      expect_client_fault(envelope("<id><![CDATA[a\u{1}b]]></id>"))
    end

    it 'refuses the noncharacter U+FFFE' do
      expect_client_fault(envelope('<id>a&#xFFFE;b</id>'))
    end

    it 'refuses a NUL character reference' do
      expect_client_fault(envelope('<id>a&#0;b</id>'))
    end

    it 'refuses a C0 control character reference' do
      expect_client_fault(envelope('<id>a&#x1;b</id>'))
    end

    it 'refuses a surrogate character reference' do
      expect_client_fault(envelope('<id>a&#xD800;b</id>'))
    end

    it 'refuses bytes that are not UTF-8' do
      expect_client_fault(envelope("<id>a\xFFb</id>".b))
    end
  end

  describe 'request structure' do
    it 'refuses a DOCTYPE, and logs why' do
      log = capture_logs { expect_client_fault(envelope('<id>x</id>', head: %(<!DOCTYPE x [<!ENTITY e "y">]>\n))) }
      expect(log).to include('DOCTYPE is not allowed')
    end

    it 'refuses a second root element after the Envelope' do
      expect_client_fault(envelope('<id>x</id>') + '<extra/>')
    end

    it 'refuses a NUL byte before the document instead of stripping it' do
      expect_client_fault("\u{0}" + envelope('<id>x</id>'))
    end

    it 'counts text nodes towards max_elements' do
      mock_controller(snakecase_input: false, camelize_wsdl: false, namespace: SERVICE_NS, max_elements: 50) do
        soap_action 'GetThingRequest', args: { id: :string }, return: { echo: :string }, to: 'get_thing'
        def get_thing
          $wash_out_hardening_calls << :ran
          render soap: { echo: 'ok' }
        end
      end
      # 40 elements, each holding text: 80 nodes.
      expect_client_fault(envelope('<id>x</id>' + '<p>t</p>' * 39))
    end

    it 'refuses more elements than max_elements' do
      mock_controller(snakecase_input: false, camelize_wsdl: false, namespace: SERVICE_NS, max_elements: 50) do
        soap_action 'GetThingRequest', args: { id: :string }, return: { echo: :string }, to: 'get_thing'
        def get_thing
          $wash_out_hardening_calls << :ran
          render soap: { echo: 'ok' }
        end
      end
      expect_client_fault(envelope('<id>x</id>' + '<pad/>' * 60))
    end

    it 'answers a parser stack overflow with a fault instead of raising' do
      allow_any_instance_of(WashOut::RequestParser).to receive(:parse).and_raise(SystemStackError)
      expect_client_fault(envelope('<id>x</id>'))
    end

    it 'refuses a repeated operation element' do
      expect_client_fault(envelope('<id>a</id>').sub('</soapenv:Body>', "<ns:GetThingRequest><id>b</id></ns:GetThingRequest></soapenv:Body>"))
    end

    it 'refuses elements nested deeper than max_nesting_depth' do
      deep = '<sku>' * 150 + 'x' + '</sku>' * 150
      expect_client_fault(envelope("<item>#{deep}</item>"))
    end

    it 'refuses a body over max_request_size before parsing it' do
      expect_client_fault(envelope('<id>x</id>' + ' ' * (1_048_576 + 1)))
    end

    it 'refuses an oversized body that has no Content-Length' do
      xml = envelope('<id>x</id>' + ' ' * (1_048_576 + 1))
      env = Rack::MockRequest.env_for('/route/api/action', method: 'POST', input: xml, 'CONTENT_TYPE' => 'text/xml')
      env.delete('CONTENT_LENGTH')
      status, _headers, _body = Dummy::Application.call(env)
      expect(status).to eq 500
      expect(calls).to be_empty
    end

    it 'refuses a Body without the SOAPAction-named operation element' do
      mock_controller(snakecase_input: false, camelize_wsdl: false, namespace: false, soap_action_routing: true) do
        soap_action 'GetThingRequest', args: { id: :string }, return: { echo: :string }, to: 'get_thing'
        def get_thing
          $wash_out_hardening_calls << :ran
          render soap: { echo: 'ok' }
        end
      end
      xml = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"><soapenv:Body>' \
            '<OtherRequest><id>x</id></OtherRequest></soapenv:Body></soapenv:Envelope>'
      env = Rack::MockRequest.env_for('/route/api/action', method: 'POST', input: xml,
                                      'CONTENT_TYPE' => 'text/xml', 'HTTP_SOAPACTION' => '"GetThingRequest"')
      expect(Dummy::Application.call(env).first).to eq 500
      expect(calls).to be_empty
    end

    it 'reads the exact operation element when the operation comes from SOAPAction' do
      mock_controller(snakecase_input: false, camelize_wsdl: false, namespace: false, soap_action_routing: true) do
        soap_action 'GetThingRequest', args: { id: :string }, return: { echo: :string }, to: 'get_thing'
        def get_thing
          $wash_out_hardening_calls << params[:id]
          render soap: { echo: 'ok' }
        end
      end
      xml = '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"><soapenv:Body>' \
            '<GetThingRequest><id>routed</id></GetThingRequest><get_thing_request><id>alias</id></get_thing_request>' \
            '</soapenv:Body></soapenv:Envelope>'
      env = Rack::MockRequest.env_for('/route/api/action', method: 'POST', input: xml,
                                      'CONTENT_TYPE' => 'text/xml', 'HTTP_SOAPACTION' => '"GetThingRequest"')
      Dummy::Application.call(env)
      expect(calls).to eq ['routed']
    end

    it 'requires an Envelope and Body when the operation comes from SOAPAction' do
      mock_controller(snakecase_input: false, camelize_wsdl: false, namespace: false, soap_action_routing: true) do
        soap_action 'GetThingRequest', args: { id: :string }, return: { echo: :string }, to: 'get_thing'
        def get_thing
          $wash_out_hardening_calls << :ran
          render soap: { echo: 'ok' }
        end
      end
      ['', '<a/>', '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"/>'].each do |xml|
        env = Rack::MockRequest.env_for('/route/api/action', method: 'POST', input: xml,
                                        'CONTENT_TYPE' => 'text/xml', 'HTTP_SOAPACTION' => '"GetThingRequest"')
        expect(Dummy::Application.call(env).first).to eq 500
      end
      expect(calls).to be_empty
    end

    it 'logs the faults it answers, without the body' do
      log = capture_logs { soap_post(envelope('<id>FAKE-PW-3</id>', op: 'NoSuchRequest')) }
      expect(log).to include('with a Client fault (undeclared operation)')
      expect(log).not_to include('FAKE-PW-3')
    end

    it 'parses the body once per request' do
      parses = 0
      allow_any_instance_of(WashOut::RequestParser).to receive(:parse).and_wrap_original { |m, *a| parses += 1; m.call(*a) }
      params_for('<id>x</id>')
      expect(parses).to eq 1
    end

    it 'answers malformed XML with a fault and keeps the body out of the logs' do
      log = capture_logs do
        expect_client_fault(envelope('<id>x</id><password>FAKE-PW-1</password></oops>'))
      end
      expect(log).to include('WashOut: rejected SOAP request (REXML::ParseException)')
      expect(log).not_to include('FAKE-PW-1')
    end

    [
      ['a text Envelope', '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">x</soapenv:Envelope>'],
      ['an Envelope without Body', '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"><soapenv:Header/></soapenv:Envelope>'],
      ['a text Body', '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"><soapenv:Body>x</soapenv:Body></soapenv:Envelope>'],
      ['a Body with only attributes', '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"><soapenv:Body a="1"/></soapenv:Envelope>'],
      ['a root element that is not an Envelope', '<r><Envelope><Body><GetThingRequest/></Body></Envelope></r>'],
      ['a repeated Body', '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"><soapenv:Body><a/></soapenv:Body><soapenv:Body><b/></soapenv:Body></soapenv:Envelope>'],
    ].each do |name, xml|
      it "answers #{name} with a fault" do
        expect_client_fault(xml)
      end
    end

    it 'answers a text operation element with a fault' do
      expect_client_fault(envelope('just text'))
    end

    it 'labels faults caused by the request as Client faults' do
      # A struct argument given text: rejected before and after the review,
      # but 0b7d787 labelled it a Server fault.
      body = expect_client_fault(envelope('<item>text</item>'))
      expect(body).to include('<faultcode xsi:type="xsd:QName">Client</faultcode>')
    end

    it 'answers an undeclared operation with a fault' do
      body = expect_client_fault(envelope('<id>x</id>', op: 'NoSuchRequest'))
      expect(body).to include('Cannot find SOAP action mapping for NoSuchRequest')
    end

    it 'reads arguments from the element it routed on' do
      xml = envelope('<id>routed</id>').sub('</soapenv:Body>', '<get_thing_request><id>sibling</id></get_thing_request></soapenv:Body>')
      soap_post(xml)
      expect(calls.last[:params]['id']).to eq 'routed'
    end
  end

  describe 'HTTP method' do
    it 'does not run an operation for GET' do
      expect_client_fault(envelope('<id>x</id>'), method: 'GET')
    end

    it 'does not run an operation for HEAD' do
      status, _body = soap_post(envelope('<id>x</id>'), method: 'HEAD')
      expect(status).to eq 500
      expect(calls).to be_empty
    end
  end

  describe 'form-encoded Content-Type' do
    ['application/x-www-form-urlencoded', nil].each do |content_type|
      it "does not form-parse or log the envelope (Content-Type #{content_type.inspect})" do
        log = capture_logs do
          status, _body = soap_post(envelope('<id>x</id><password>FAKE-PW-2</password>'), content_type: content_type)
          expect(status).to eq 200
        end
        expect(calls.last[:request_parameters]).to eq({})
        expect(log).not_to include('FAKE-PW-2')
      end
    end
  end

  describe 'WSSE' do
    def digest(nonce, created, password)
      Base64.encode64(Digest::SHA1.hexdigest(nonce + created + password)).chomp
    end

    def token_xml(username, password: nil)
      pw = password ? "<wsse:Password>#{password}</wsse:Password>" : ''
      %(<soapenv:Header><wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">) +
        %(<wsse:UsernameToken><wsse:Username>#{username}</wsse:Username>#{pw}</wsse:UsernameToken></wsse:Security></soapenv:Header>)
    end

    def wsse_controller(**config)
      mock_controller({ snakecase_input: false, camelize_wsdl: false, namespace: SERVICE_NS,
                        prefix: 'ns1', soap_action_routing: false, wsdl_style: 'rpc' }.merge(config)) do
        soap_action 'GetThingRequest', args: { id: :string }, return: { echo: :string },
          to: 'get_thing', response_tag: 'GetThingResponse'
        def get_thing
          $wash_out_hardening_calls << { wsse_token: request.env['WSSE_TOKEN'], wsse_username: wsse_username }
          render soap: { echo: 'ok' }
        end
      end
    end

    it 'computes the digest over Created as sent, so the offset cannot be rewritten' do
      nonce   = Base64.strict_encode64('n' * 16)
      old     = Time.now.utc - 3600
      sent    = old.strftime('%Y-%m-%dT%H:%M:%SZ')
      digest  = digest(nonce, sent, 'secret')
      # Same wall-clock text with a -01:00 offset: an instant that is "now".
      shifted = old.strftime('%Y-%m-%dT%H:%M:%S-01:00')
      expect(WashOut::Wsse.matches_expected_digest?('secret', digest, nonce, shifted)).to eq false
    end

    it 'refuses a Created time in the future' do
      nonce   = Base64.strict_encode64('n' * 16)
      created = (Time.now.utc + 3600).strftime('%Y-%m-%dT%H:%M:%SZ')
      expect(WashOut::Wsse.matches_expected_digest?('secret', digest(nonce, created, 'secret'), nonce, created)).to eq false
    end

    it 'accepts a current digest' do
      nonce   = Base64.strict_encode64('n' * 16)
      created = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
      expect(WashOut::Wsse.matches_expected_digest?('secret', digest(nonce, created, 'secret'), nonce, created)).to eq true
    end

    it 'does not accept a token without a password when no password is configured' do
      wsse_controller(wsse_username: 'gorilla')
      xml = envelope('<id>x</id>').sub('<soapenv:Header/>', token_xml('gorilla'))
      expect_client_fault(xml)
    end

    it 'refuses a Created time older than five minutes' do
      nonce   = Base64.strict_encode64('n' * 16)
      created = (Time.now.utc - 600).strftime('%Y-%m-%dT%H:%M:%SZ')
      expect(WashOut::Wsse.matches_expected_digest?('secret', digest(nonce, created, 'secret'), nonce, created)).to eq false
    end

    it 'accepts the Java / SoapUI digest flavour' do
      raw     = 'n' * 16
      nonce   = Base64.strict_encode64(raw)
      created = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
      java    = Base64.strict_encode64(Digest::SHA1.digest(raw + created + 'secret'))
      expect(WashOut::Wsse.matches_expected_digest?('secret', java, nonce, created)).to eq true
    end

    it 'does not switch WSSE off when only a password is configured' do
      wsse_controller(wsse_password: 'secret')
      expect_client_fault(envelope('<id>x</id>'))
    end

    it 'refuses a token that carries both spellings of a field' do
      wsse_controller(wsse_username: 'gorilla', wsse_password: 'secret')
      token = token_xml('gorilla', password: 'secret').sub('</wsse:Username>', '</wsse:Username><wsse:username>other</wsse:username>')
      expect_client_fault(envelope('<id>x</id>').sub('<soapenv:Header/>', token))
    end

    it 'publishes only the checked fields as WSSE_TOKEN, and labels failures Client' do
      wsse_controller(wsse_username: 'gorilla', wsse_password: 'secret')
      token = token_xml('gorilla', password: 'secret').sub('</wsse:UsernameToken>', '<wsse:Role>admin</wsse:Role></wsse:UsernameToken>')
      soap_post(envelope('<id>x</id>').sub('<soapenv:Header/>', token))
      expect(calls.last[:wsse_token].keys).to contain_exactly('Username', 'Password') # the caller's spelling; no Role

      calls.clear
      body = expect_client_fault(envelope('<id>x</id>').sub('<soapenv:Header/>', token_xml('gorilla', password: 'wrong')))
      expect(body).to include('<faultcode xsi:type="xsd:QName">Client</faultcode>')
    end

    it 'fails closed when the auth callback has the wrong arity' do
      wsse_controller(wsse_auth_callback: lambda { |user, password| true })
      status, _body = soap_post(envelope('<id>x</id>'))
      expect(status).to eq 500
      expect(calls).to be_empty
    end

    it 'leaves Nonce and Created out of WSSE_TOKEN when only the plain password was checked' do
      wsse_controller(wsse_username: 'gorilla', wsse_password: 'secret')
      token = token_xml('gorilla', password: 'secret').sub('</wsse:UsernameToken>',
        '<wsse:Nonce>bm9uY2U=</wsse:Nonce><wsu:Created xmlns:wsu="urn:wsu">2000-01-01T00:00:00Z</wsu:Created></wsse:UsernameToken>')
      soap_post(envelope('<id>x</id>').sub('<soapenv:Header/>', token))
      expect(calls.last[:wsse_token].keys).to contain_exactly('Username', 'Password')
    end

    it 'does not expose an unchecked UsernameToken when WSSE is off' do
      wsse_controller
      soap_post(envelope('<id>x</id>').sub('<soapenv:Header/>', token_xml('admin', password: 'x')))
      expect(calls.last).to eq(wsse_token: nil, wsse_username: nil)
    end
  end

  describe 'requests without a declared operation' do
    # The app authenticates in a before_action; for these requests it would
    # only see query-string parameters.
    before do
      mock_controller(
        snakecase_input: false, camelize_wsdl: false, namespace: SERVICE_NS,
        prefix: 'ns1', soap_action_routing: false, wsdl_style: 'rpc'
      ) do
        before_action { $wash_out_hardening_calls << { callback: action_name, id: params[:id] } }
        soap_action 'GetThingRequest', args: { id: :string }, return: { echo: :string },
          to: 'get_thing', response_tag: 'GetThingResponse'
        def get_thing
          render soap: { echo: 'ok' }
        end
      end
    end

    def post_to(path, xml)
      env = Rack::MockRequest.env_for(path, method: 'POST', input: xml, 'CONTENT_TYPE' => 'text/xml')
      status, _headers, body = Dummy::Application.call(env)
      text = +''
      body.each { |chunk| text << chunk }
      [status, text]
    end

    it 'answers an empty body without running controller callbacks' do
      status, body = post_to('/route/api/action?id=cust&password=s3cret', '')
      expect(status).to eq 500
      expect(body).to include('Invalid SOAP request')
      expect(calls).to be_empty
    end

    it 'answers an undeclared operation without running controller callbacks' do
      status, body = post_to('/route/api/action?id=cust', envelope('<id>x</id>', op: 'NoSuchRequest'))
      expect(status).to eq 500
      expect(body).to include('Cannot find SOAP action mapping for NoSuchRequest')
      expect(calls).to be_empty
    end

    it 'still runs callbacks, with body parameters, for a declared operation' do
      post_to('/route/api/action?id=from-query', envelope('<id>from-body</id>'))
      expect(calls).to eq [{ callback: 'get_thing', id: 'from-body' }]
    end
  end

  describe 'WSDL endpoint' do
    def wsdl(headers = {})
      env = Rack::MockRequest.env_for('/route/api/wsdl', { method: 'GET' }.merge(headers))
      _status, _headers, body = Dummy::Application.call(env)
      text = +''
      body.each { |chunk| text << chunk }
      text[/soap:address location="([^"]*)"/, 1]
    end

    def wsdl_controller(**config)
      mock_controller({ snakecase_input: false, camelize_wsdl: false, namespace: SERVICE_NS,
                        prefix: 'ns1', soap_action_routing: false, wsdl_style: 'rpc' }.merge(config)) do
        soap_action 'GetThingRequest', args: { id: :string }, return: { echo: :string },
          to: 'get_thing', response_tag: 'GetThingResponse'
      end
    end

    it 'uses endpoint_base_url instead of the Host / X-Forwarded-Host the caller sent' do
      wsdl_controller(endpoint_base_url: 'https://ps.example.com/')
      expect(wsdl('HTTP_X_FORWARDED_HOST' => 'attacker.example')).to eq 'https://ps.example.com/route/api/action'
    end

    it 'refuses an endpoint_base_url that is not a plain http(s) origin' do
      expect { wsdl_controller(endpoint_base_url: 'https://user:pw@ps.example.com') }.to raise_error(ArgumentError)
      expect { wsdl_controller(endpoint_base_url: 'javascript:alert(1)') }.to raise_error(ArgumentError)
    end
  end

  describe 'service configuration' do
    it 'does not let a subclass change its parent service config' do
      parent = Class.new(ApplicationController) { soap_service namespace: 'urn:parent', prefix: 'p' }
      child  = Class.new(parent) { soap_service namespace: 'urn:child' }
      expect(parent.soap_config.namespace).to eq 'urn:parent'
      expect(child.soap_config.namespace).to eq 'urn:child'
      expect(child.soap_config.prefix).to eq 'p'
    end

    it 'gives a subclass its own copy of the parent operations' do
      parent = Class.new(ApplicationController) { soap_service; soap_action 'a', args: nil, return: nil }
      child  = Class.new(parent) { soap_action 'b', args: nil, return: nil }
      expect(child.soap_actions.keys).to eq %w[a b]
      expect(parent.soap_actions.keys).to eq %w[a]
    end

    it 'does not list wash_out internals as controller actions' do
      controller = Class.new(ApplicationController) { soap_service }
      expect(controller.action_methods).not_to include('soap_config=', '_load_params', '_render_soap', 'render_soap_error')
      expect(controller.action_methods).to include('_generate_wsdl', '_invalid_action', '_invalid_request')
    end

    it 'rejects a prefix or namespaces that are not XML names' do
      expect { Class.new(ApplicationController) { soap_service prefix: 'a b' } }.to raise_error(ArgumentError)
      expect { Class.new(ApplicationController) { soap_service namespaces: [{ 'xmlns:x"y' => 'urn:x' }] } }.to raise_error(ArgumentError)
      expect { Class.new(ApplicationController) { soap_service wsdl_style: '../x' } }.to raise_error(ArgumentError)
    end

    it 'leaves the parent untouched when a subclass config is rejected' do
      parent = Class.new(ApplicationController) { soap_service prefix: 'p' }
      child  = Class.new(parent)
      expect { child.soap_service prefix: 'a b' }.to raise_error(ArgumentError)
      child.soap_service prefix: 'c'
      expect(parent.soap_config.prefix).to eq 'p'
      expect(child.soap_config.prefix).to eq 'c'
    end

    it 'rebinds inherited operations to a subclass prefix' do
      parent = Class.new(ApplicationController) { soap_service prefix: 'p'; soap_action 'a', args: { x: :string }, return: { y: :string } }
      child  = Class.new(parent) { soap_service prefix: 'c' }
      expect(child.soap_actions['a'][:out].first.soap_config.prefix).to eq 'c'
      expect(parent.soap_actions['a'][:out].first.soap_config.prefix).to eq 'p'
    end

    it 'validates values set through the config writers' do
      config = WashOut::SoapConfig.new(prefix: 'p')
      expect { config.prefix = 'a b' }.to raise_error(ArgumentError)
      config.prefix = 'q'
      expect(config[:prefix]).to eq 'q'
    end

    it 'rejects reserved prefixes, colliding namespaces, unknown parsers and endpoint paths' do
      expect { WashOut::SoapConfig.new(prefix: 'soap') }.to raise_error(ArgumentError)
      expect { WashOut::SoapConfig.new(prefix: 'xsi') }.to raise_error(ArgumentError)
      expect { WashOut::SoapConfig.new(prefix: 'p', namespaces: [{ 'xmlns:p' => 'urn:x' }]) }.to raise_error(ArgumentError)
      expect { WashOut::SoapConfig.new(namespaces: [{ 'xmlns:xsd' => 'urn:x' }]) }.to raise_error(ArgumentError)
      expect { WashOut::SoapConfig.new(parser: :anything) }.to raise_error(ArgumentError)
      expect { WashOut::SoapConfig.new(endpoint_base_url: 'https://ps.example.com/soap') }.to raise_error(ArgumentError)
    end

    it 'accepts the production service configs' do
      config = WashOut::SoapConfig.new(prefix: 'ns2', namespaces: [{ 'xmlns:ns1': 'urn:shared' }])
      expect(config.namespaces).to eq [{ 'xmlns:ns1' => 'urn:shared' }]
    end

    it 'refuses an argument attribute named @type, which the router drops' do
      expect {
        Class.new(ApplicationController) { soap_service; soap_action 'a', args: { :@type => :string }, return: nil }
      }.to raise_error(ArgumentError, /@type/)
    end

    it 'keeps wash_out route options out of routes drawn after it' do
      routes = ActionDispatch::Routing::RouteSet.new
      routes.draw do
        wash_out :api, module: 'space'
        get 'later' => 'things#show'
      end
      later = routes.routes.find { |r| r.path.spec.to_s.start_with?('/later') }
      expect(later.defaults[:controller]).to eq 'things'
    end

    it 'keeps 0b7d787 route option semantics inside a namespace, without Rails deprecations' do
      routes = ActionDispatch::Routing::RouteSet.new
      expect(ActionDispatch.deprecator).not_to receive(:warn)
      routes.draw do
        namespace :route do
          wash_out :api, module: 'space'
        end
      end
      soap = routes.routes.find { |r| r.path.spec.to_s.end_with?('/api/action(.:format)') || r.path.spec.to_s.end_with?('/api/action') }
      expect(soap.defaults[:controller]).to eq 'space/api'
    end

    it 'checks a later prefix change against the stored namespaces' do
      config = WashOut::SoapConfig.new(prefix: 'p', namespaces: [{ 'xmlns:q' => 'urn:x' }])
      expect { config.prefix = 'q' }.to raise_error(ArgumentError)
      expect { WashOut::SoapConfig.new(namespaces: [{ 'xmlns:tns' => 'urn:x' }]) }.to raise_error(ArgumentError)
      expect { WashOut::SoapConfig.new(namespaces: [{ 'xmlns:a' => 'urn:x' }, { 'xmlns:a' => 'urn:y' }]) }.to raise_error(ArgumentError)
    end

    it 'freezes the config soap_service builds, so nothing else can change it' do
      parent = Class.new(ApplicationController) { soap_service prefix: 'p' }
      child  = Class.new(parent)
      expect { child.soap_config.prefix = 'x' }.to raise_error(FrozenError)
      expect(parent.soap_config.prefix).to eq 'p'
      parent.soap_service prefix: 'q'
      expect(parent.soap_config.prefix).to eq 'q'
    end

    it 'caps max_nesting_depth below what Nori can convert' do
      expect { WashOut::SoapConfig.new(max_nesting_depth: 500) }.to raise_error(ArgumentError)
    end

    it 'publishes model columns of any type as types requests can be read into' do
      column = Struct.new(:type)
      model = Class.new do
        extend WashOut::Model
        define_singleton_method(:name) { 'Gadget' }
        define_singleton_method(:wash_out_columns) do
          { 'id' => column.new(:uuid), 'blob' => column.new(:binary), 'meta' => column.new(:json), 'qty' => column.new(:integer) }
        end
      end
      expect(model.wash_out_param_map).to eq('id' => :string, 'blob' => :base64Binary, 'meta' => :string, 'qty' => :integer)
      expect { Class.new(ApplicationController) { soap_service; soap_action 'a', args: { g: model }, return: nil } }.not_to raise_error
    end

    it 'refuses argument types that requests cannot be read into' do
      expect {
        Class.new(ApplicationController) { soap_service; soap_action 'a', args: { note: :text }, return: nil }
      }.to raise_error(ArgumentError, /text/)
    end

    it 'does not warn about dropped keys for an operation that returns nothing' do
      mock_controller(snakecase_input: false, camelize_wsdl: false, namespace: SERVICE_NS) do
        soap_action 'GetThingRequest', args: { id: :string }, return: nil, to: 'get_thing'
        def get_thing
          render soap: nil
        end
      end
      log = capture_logs { soap_post(envelope('<id>x</id>')) }
      expect(log).not_to include('undeclared')
    end

    it 'can freeze a config more than once, deep enough for namespace values' do
      ns_uri = +'urn:shared'
      config = WashOut::SoapConfig.new(namespaces: [{ 'xmlns:shar' => ns_uri }]).freeze
      expect(config.freeze).to equal(config)
      ns_uri.replace('urn:changed')
      expect(config.namespaces.first['xmlns:shar']).to eq 'urn:shared'
    end

    it 'keeps the WSDL route reachable through url_for' do
      url = Dummy::Application.routes.url_for(controller: 'route/space/api', action: '_generate_wsdl', only_path: true)
      expect(url).to eq '/route/api/wsdl'
    end

    it 'keeps the defaults immutable' do
      expect(WashOut::SoapConfig::DEFAULT_CONFIG).to be_frozen
      expect(WashOut::SoapConfig::DEFAULT_CONFIG[:namespaces]).to be_frozen
    end
  end

  describe 'response namespaces' do
    it 'declares xsd in the rpc fault, where xsi:type values use it' do
      body = expect_client_fault(envelope('<item>text</item>'))
      expect(body).to include('xmlns:xsd="http://www.w3.org/2001/XMLSchema"')
    end

    it 'declares xsi and xsd on the rpc response header element' do
      mock_controller(
        snakecase_input: false, camelize_wsdl: false, namespace: SERVICE_NS,
        prefix: 'ns1', soap_action_routing: false, wsdl_style: 'rpc'
      ) do
        soap_action 'GetThingRequest', args: { id: :string }, return: { echo: :string },
          header_return: { token: :string }, to: 'get_thing', response_tag: 'GetThingResponse'
        def get_thing
          render soap: { echo: 'ok' }, header: { token: 't' }
        end
      end
      _status, body = soap_post(envelope('<id>x</id>'))
      header = body[%r{<soap:Header>.*</soap:Header>}m]
      expect(header).to include('xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"')
    end
  end

  describe 'gemspec' do
    let(:spec) { Gem::Specification.load(File.expand_path('../../../wash_out.gemspec', __dir__)) }

    def requirement(name)
      spec.dependencies.find { |d| d.name == name }&.requirement
    end

    it 'excludes nori versions with the typecasting RCE (CVE-2013-0285)' do
      expect(requirement('nori')).not_to be_satisfied_by(Gem::Version.new('2.0.0'))
    end

    it 'requires a nori that accepts every option the router passes (2.7+)' do
      expect(requirement('nori')).not_to be_satisfied_by(Gem::Version.new('2.6.0'))
      expect(requirement('nori')).to be_satisfied_by(Gem::Version.new('2.7.1'))
    end

    it 'enforces its checks through the public Nori#parse' do
      expect(WashOut::RequestParser.public_method_defined?(:parse, false)).to be true
      expect { WashOut::RequestParser.new({ parser: :rexml }).parse('<!DOCTYPE x><x/>') }
        .to raise_error(WashOut::RequestParser::Error)
    end

    it 'requires a rexml with the 2024-2025 DoS fixes' do
      expect(requirement('rexml')).not_to be_satisfied_by(Gem::Version.new('3.4.1'))
      expect(requirement('rexml')).to be_satisfied_by(Gem::Version.new('3.4.4'))
    end
  end

  describe 'other routing modes' do
    it 'maps arguments with snakecase_input' do
      mock_controller(snakecase_input: true, camelize_wsdl: false, namespace: SERVICE_NS, soap_action_routing: false) do
        soap_action 'get_thing', args: { item_id: :integer }, return: { echo: :string }, to: 'get_thing'
        def get_thing
          $wash_out_hardening_calls << params[:item_id]
          render soap: { echo: 'ok' }
        end
      end
      expect(soap_post(envelope('<ItemId>7</ItemId>', op: 'GetThing')).first).to eq 200
      expect(calls).to eq [7]
    end

    it 'answers a malformed document-style request with a document fault' do
      mock_controller(snakecase_input: false, camelize_wsdl: false, namespace: SERVICE_NS, wsdl_style: 'document') do
        soap_action 'GetThingRequest', args: { id: :string }, return: { echo: :string }, to: 'get_thing'
      end
      status, body = soap_post('<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"><oops>')
      expect(status).to eq 500
      expect(body).to include('<faultcode>Client</faultcode>')
    end
  end

  describe 'document style' do
    before do
      mock_controller(snakecase_input: false, camelize_wsdl: false, namespace: SERVICE_NS, wsdl_style: 'document') do
        soap_action 'id', args: { id: :string, tags: [:string] }, return: { echo: :string }, to: 'get_thing'
        def get_thing
          $wash_out_hardening_calls << params.to_unsafe_h
          render soap: { echo: 'ok' }
        end
      end
    end

    def document(parts)
      %(<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"><soapenv:Body>#{parts}</soapenv:Body></soapenv:Envelope>)
    end

    it 'accepts simple and repeated message parts' do
      expect(soap_post(document('<id>a</id><tags>x</tags><tags>y</tags>')).first).to eq 200
      expect(calls.last).to include('id' => 'a', 'tags' => ['x', 'y'])
    end

    it 'refuses an href on a message part' do
      expect_client_fault(document('<id>a</id><tags href="#t"/><t id="t">x</t>'))
    end
  end

  describe 'other request encodings' do
    it 'accepts a UTF-16 (BOM) request' do
      xml = envelope('<id>utf16</id>').sub('encoding="UTF-8"', 'encoding="UTF-16"')
      body = "\xFF\xFE".b + xml.encode('UTF-16LE').b
      expect(soap_post(body).first).to eq 200
      expect(calls.last[:params]['id']).to eq 'utf16'
    end

    it 'accepts a request in a legacy multi-byte encoding (GBK)' do
      xml = envelope('<id>X</id>').sub('encoding="UTF-8"', 'encoding="GBK"')
      body = xml.b.sub('X'.b, "\xEF\xBF\xBE\xA9".b) # "锟京" in GBK
      expect(soap_post(body).first).to eq 200
      expect(calls.last[:params]['id']).to eq "\xEF\xBF\xBE\xA9".dup.force_encoding('GBK').encode('UTF-8')
    end

    it 'refuses control characters in markup and comments that REXML would skip' do
      expect_client_fault(envelope('<id>x</id>').sub('<soapenv:Header/>', "<soapenv:Header\v/>"))
      expect_client_fault(envelope("<id>x</id><!-- a\u{1}b -->"))
    end

    it 'does not form-parse a body that contains % escapes' do
      status, _body = soap_post(envelope('<id>50%25 off %zz</id>'), content_type: 'application/x-www-form-urlencoded')
      expect(status).to eq 200
      expect(calls.last[:request_parameters]).to eq({})
    end

    it 'does not break on a multipart Content-Type' do
      status, _body = soap_post(envelope('<id>x</id>'), content_type: 'multipart/form-data; boundary=xyz')
      expect(status).to eq 200
      expect(calls.last[:params]['id']).to eq 'x'
    end
  end

  describe 'WSDL endpoint configuration' do
    it 'does not log a form-typed body sent to the WSDL' do
      mock_controller(snakecase_input: false, camelize_wsdl: false, namespace: SERVICE_NS) do
        soap_action 'GetThingRequest', args: { id: :string }, return: { echo: :string }, to: 'get_thing'
      end
      log = capture_logs do
        env = Rack::MockRequest.env_for('/route/api/wsdl', method: 'GET', input: 'password=FAKE-PW-4',
                                        'CONTENT_TYPE' => 'application/x-www-form-urlencoded')
        expect(Dummy::Application.call(env).first).to eq 200
      end
      expect(log).not_to include('FAKE-PW-4')
    end

    it 'takes endpoint_base_url from config.wash_out' do
      previous = WashOut::Engine.config.wash_out
      WashOut::Engine.config.wash_out = previous.merge(endpoint_base_url: 'https://app-wide.example.com')
      begin
        mock_controller(snakecase_input: false, camelize_wsdl: false, namespace: SERVICE_NS) do
          soap_action 'GetThingRequest', args: { id: :string }, return: { echo: :string }, to: 'get_thing'
        end
        env = Rack::MockRequest.env_for('/route/api/wsdl', 'HTTP_X_FORWARDED_HOST' => 'attacker.example')
        _status, _headers, body = Dummy::Application.call(env)
        text = +''
        body.each { |chunk| text << chunk }
        expect(text).to include('location="https://app-wide.example.com/route/api/action"')
      ensure
        WashOut::Engine.config.wash_out = previous
      end
    end

    it 'raises instead of advertising the route table when no route matches' do
      request = ActionDispatch::Request.new(Rack::MockRequest.env_for('/'))
      expect { WashOut::Router.url(request, 'no/such_controller') }.to raise_error(WashOut::Router::RouteNotFound)
    end
  end

  describe 'responses' do
    it 'writes Symbol values as text' do
      mock_controller(
        snakecase_input: false, camelize_wsdl: false, namespace: SERVICE_NS,
        prefix: 'ns1', soap_action_routing: false, wsdl_style: 'rpc'
      ) do
        soap_action 'GetThingRequest', namespace_everything: true, skip_xsi_types: true,
          args: { id: :string }, return: { echo: :string }, to: 'get_thing', response_tag: 'GetThingResponse'
        def get_thing
          render soap: { echo: :abc }
        end
      end

      status, body = soap_post(envelope('<id>x</id>'))
      expect(status).to eq 200
      expect(body).to include('<ns1:echo>abc</ns1:echo>')
    end

    it 'raises when the app returns a Hash for a simple-type value' do
      mock_controller(snakecase_input: false, camelize_wsdl: false, namespace: SERVICE_NS, prefix: 'ns1', soap_action_routing: false) do
        soap_action 'GetThingRequest', args: { id: :string }, return: { echo: :string }, to: 'get_thing'
        def get_thing
          render soap: { echo: { 'onclick' => 'x' } }
        end
      end
      expect { soap_post(envelope('<id>x</id>')) }.to raise_error(WashOut::Dispatcher::ProgrammerError)
    end
  end
end
