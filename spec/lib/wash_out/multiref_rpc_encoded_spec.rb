require 'spec_helper'
require 'timeout'

# An rpc/encoded (Axis 1 style) SendPO where every complex value is a
# Body-level multiRef referenced exactly once, so nothing is shared.
# MultiRef used to copy those Body-level elements in place as well as through
# each href: about (multiRef depth + 1) x the input, which went past the 8x
# budget for a decorated PO. They are now expanded only where referenced.
# 0b7d787 accepts this message too.
describe 'Axis-style rpc/encoded PO with deep multiRefs (no shared references)' do
  AXIS_NS = 'http://www.promostandards.org/WSDL/Test/1.0.0/'
  AXIS_ATTRS = %( soapenc:root="0" soapenv:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/" xmlns:soapenc="http://schemas.xmlsoap.org/soap/encoding/" xmlns:ns2="urn:x")
  around { |ex| Timeout.timeout(20) { ex.run } }

  def emit(name, value, refs, ids)
    case value
    when Array then value.map { |v| emit(name, v, refs, ids) }.join
    when Hash
      i = (ids[0] += 1)
      refs << %(<multiRef id="id#{i}"#{AXIS_ATTRS} xsi:type="ns2:#{name}">#{value.map { |k, v| emit(k, v, refs, ids) }.join}</multiRef>)
      %(<#{name} href="#id#{i}"/>)
    else %(<#{name} xsi:type="xsd:string">#{value}</#{name}>)
    end
  end

  def line_item(j)
    layers = (1..6).map { |k| { nameOrNumber: k.to_s, description: "c#{k}", color: "PMS #{k}" } }
    typesets = (1..2).map { |k| { sequenceNumber: k.to_s, value: 't', font: 'Arial', fontSize: '10' } }
    deco = ->(d) { { decorationId: d.to_s, decorationName: 'Screen',
      Artwork: { refArtworkId: "a#{j}", description: 'd', Dimensions: { geometry: 'Rect', height: '1.0', width: '2.0', uom: 'IN' },
        instructions: 'none', Layers: { colorSystem: 'Pms', LayerOrStopArray: { LayerOrStop: layers } }, TypesetArray: { Typeset: typesets } } } }
    loc = ->(l) { { locationId: l.to_s, locationName: 'Front', DecorationArray: { Decoration: [deco.(1), deco.(2)] } } }
    { lineNumber: j.to_s, description: "item #{j}", lineType: 'New', Quantity: { uom: 'EA', value: '10' }, fobId: '1', productId: "P#{j}",
      PartArray: { Part: [{ partId: "P#{j}-1", Quantity: { uom: 'EA', value: '10' } }] },
      Configuration: { referenceNumber: 'r', preProductionProof: 'false', LocationArray: { Location: [loc.(1), loc.(2)] } } }
  end

  it 'resolves an 8-line decorated PO (193 KB) instead of answering Invalid SOAP request' do
    $axis_seen = nil
    mock_controller(snakecase_input: false, camelize_wsdl: false, namespace: AXIS_NS, prefix: 'ns1',
                    soap_action_routing: false, wsdl_style: 'rpc') do
      soap_action 'SendPORequest', namespace_everything: true, skip_blanks: true, skip_xsi_types: true,
        args: { id: :string, PO: { orderNumber: :string, LineItemArray: { LineItem: [{ productId: :string }] } } },
        return: { ok: :string }, to: 'send_po'
      def send_po; $axis_seen = params.to_unsafe_h; render soap: { ok: 'ok' }; end
    end
    refs = []; ids = [0]
    po = { orderType: 'Configured', orderNumber: 'PO1', LineItemArray: { LineItem: (1..8).map { |j| line_item(j) } } }
    inner = %(<id xsi:type="xsd:string">u</id>) + emit('PO', po, refs, ids)
    xml = %(<?xml version="1.0" encoding="UTF-8"?><soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><soapenv:Body><ns1:SendPORequest xmlns:ns1="#{AXIS_NS}">#{inner}</ns1:SendPORequest>#{refs.join}</soapenv:Body></soapenv:Envelope>)
    expect(xml.bytesize).to be < 200_000
    env = Rack::MockRequest.env_for('/route/api/action', method: 'POST', input: xml, 'CONTENT_TYPE' => 'text/xml; charset=utf-8')
    status, _h, body = Dummy::Application.call(env)
    text = +''; body.each { |c| text << c }
    expect(text).not_to include('Invalid SOAP request')
    expect(status).to eq 200
    expect($axis_seen['PO']['LineItemArray']['LineItem'].size).to eq 8
  end
end
