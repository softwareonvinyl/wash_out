require 'spec_helper'
require 'timeout'

# multiRef resolution budget: work is charged per container visited and per
# entry copied, so shared references cannot multiply the resolved tree.
# Small inputs only (< 40 KB, well under a second).
describe 'WashOut multiRef budget counts entries' do
  BUDGET_SERVICE_NS = 'http://www.promostandards.org/WSDL/Test/1.0.0/'
  around { |ex| Timeout.timeout(10) { ex.run } }

  before do
    $wash_out_budget_calls = []
    mock_controller(
      snakecase_input: false, camelize_wsdl: false, namespace: BUDGET_SERVICE_NS,
      prefix: 'ns1', soap_action_routing: false, wsdl_style: 'rpc'
    ) do
      soap_action 'GetThingRequest',
        namespace_everything: true, skip_blanks: true, skip_xsi_types: true,
        args: { id: :string, item: { sku: :string }, items: [{ sku: :string }],
                PO: { orderNumber: :string, LineItemArray: { item: [{ productId: :string }] } } },
        return: { echo: :string }, to: 'get_thing'
      def get_thing
        $wash_out_budget_calls << params.to_unsafe_h
        render soap: { echo: params[:id].to_s }
      end
    end
  end

  def post(inner, extra = '')
    xml = %(<?xml version="1.0" encoding="UTF-8"?><soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns="#{BUDGET_SERVICE_NS}"><soapenv:Header/><soapenv:Body><ns:GetThingRequest>#{inner}</ns:GetThingRequest>#{extra}</soapenv:Body></soapenv:Envelope>)
    env = Rack::MockRequest.env_for('/route/api/action', method: 'POST', input: xml, 'CONTENT_TYPE' => 'text/xml; charset=utf-8')
    status, _h, body = Dummy::Application.call(env)
    text = +''; body.each { |c| text << c }; body.close if body.respond_to?(:close)
    [status, text, xml.bytesize]
  end

  def slots(node)
    case node
    when Hash  then node.size + node.each_value.sum { |v| slots(v) }
    when Array then node.size + node.sum { |v| slots(v) }
    else 0
    end
  end

  # Records the size of every tree MultiRef.resolve returns.
  def watch_resolve
    sizes = []
    allow(WashOut::MultiRef).to receive(:resolve).and_wrap_original { |m, *a, **k| m.call(*a, **k).tap { |r| sizes << slots(r) } }
    sizes
  end

  it 'refuses R references to one wide target in the router (flat)' do
    sizes = watch_resolve
    status, body, bytes = post('<ns:id>u</ns:id>' + ('<ns:items href="#big"/>' * 1000),
                               '<b id="big">' + ('<x>1</x>' * 1000) + '</b>')
    expect(bytes).to be < 40_000
    expect(status).to eq 500
    expect(body).to include('Invalid SOAP request') # router reject, not a Param fault
    expect(sizes).to be_empty                       # resolve raised, nothing built
    expect($wash_out_budget_calls).to be_empty
  end

  it 'refuses a doubling DAG over a wide target (2**8 copies of 500 entries from 4.5 KB)' do
    sizes = watch_resolve
    levels = (0...8).map { |i| %(<n id="a#{i}"><l href="#a#{i + 1}"/><r href="#a#{i + 1}"/></n>) }.join
    status, body, bytes = post('<ns:id>u</ns:id><ns:item href="#a0"/>', levels + %(<n id="a8">#{'<x>1</x>' * 500}</n>))
    expect(bytes).to be < 5_000
    expect(status).to eq 500
    expect(body).to include('Invalid SOAP request')
    expect(sizes).to be_empty
    expect($wash_out_budget_calls).to be_empty
  end

  it 'refuses a long href chain reached from many references (hops are charged)' do
    chain = (0...90).map { |i| %(<c id="c#{i}" href="#c#{i + 1}"/>) }.join + '<c id="c90"><sku>s</sku></c>'
    status, body, = post('<ns:id>u</ns:id>' + ('<ns:items href="#c0"/>' * 2000), chain)
    expect(status).to eq 500
    expect(body).to include('Invalid SOAP request')
  end

  it 'still accepts a modest number of references to a shared target' do
    sizes = watch_resolve
    # 50 refs to a 100-entry target: ~5,300 output slots, under the floor.
    status, _body, = post('<ns:id>u</ns:id>' + ('<ns:items href="#t"/>' * 50),
                          '<t id="t"><sku>s</sku>' + ('<x>1</x>' * 99) + '</t>')
    expect(status).to eq 200
    expect(sizes.last).to be < 10_000
    expect($wash_out_budget_calls.last['items'].size).to eq 50
  end

  # rpc/encoded clients (Axis 1, .NET SoapRpcMethod) send every complex value
  # as its own Body-level multiRef, each referenced once.
  it 'still resolves an rpc/encoded purchase order with 200 line items' do
    id = 0; refs = []
    mk = ->(body) { i = (id += 1); refs << %(<multiRef id="id#{i}">#{body}</multiRef>); %(href="#id#{i}") }
    items = (1..200).map do |j|
      q1 = mk.(%(<value>1</value><uom>EA</uom>)); q2 = mk.(%(<value>2</value><uom>EA</uom>))
      part = mk.(%(<partId>P#{j}</partId><partGroup>1</partGroup><Quantity #{q2}/>))
      pa = mk.(%(<Part #{part}/>))
      li = mk.(%(<sku>X#{j}</sku><description>d</description><lineType>New</lineType><Quantity #{q1}/><PartArray #{pa}/>))
      %(<ns:items #{li}/>)
    end.join
    status, body, = post('<ns:id>u</ns:id>' + items, refs.join)
    expect(status).to eq(200), body[0, 300]
    expect($wash_out_budget_calls.last['items'].map { |h| h['sku'] }).to eq((1..200).map { |j| "X#{j}" })
  end

  it 'still resolves an rpc/encoded PO whose every level is a multiRef (50 line items)' do
    # op -> PO -> LineItemArray -> LineItem -> PartArray -> Part -> Quantity
    id = 0; refs = []
    mk = ->(body) { i = (id += 1); refs << %(<multiRef id="id#{i}" soapenc:root="0">#{body}</multiRef>); %(href="#id#{i}") }
    items = (1..50).map do |j|
      q1 = mk.(%(<value>1</value><uom>EA</uom>)); q2 = mk.(%(<value>2</value><uom>EA</uom>))
      part = mk.(%(<partId>P#{j}</partId><partGroup>1</partGroup><Quantity #{q2}/>))
      pa = mk.(%(<Part #{part}/>))
      li = mk.(%(<lineNumber>#{j}</lineNumber><description>d</description><lineType>New</lineType><fobId>1</fobId><productId>X#{j}</productId><Quantity #{q1}/><PartArray #{pa}/>))
      %(<item #{li}/>)
    end.join
    lia = mk.(items)
    po = mk.(%(<orderType>Blank</orderType><orderNumber>PO1</orderNumber><totalAmount>1.00</totalAmount><LineItemArray #{lia}/>))
    status, body, = post(%(<ns:id>u</ns:id><ns:PO #{po}/>), refs.join.gsub('soapenc:root', 'root'))
    expect(status).to eq(200), body[0, 300]
    expect($wash_out_budget_calls.last['PO']['LineItemArray']['item'].map { |h| h['productId'] }).to eq((1..50).map { |j| "X#{j}" })
  end

  it 'still resolves an Axis-style message with many distinct multiRefs' do
    # 300 items, each referenced once, each with its own 20-entry target.
    refs    = (0...300).map { |i| %(<ns:items href="#id#{i}"/>) }.join
    targets = (0...300).map { |i| %(<multiRef id="id#{i}"><sku>s#{i}</sku>#{'<pad>p</pad>' * 19}</multiRef>) }.join
    status, body, = post('<ns:id>u</ns:id>' + refs, targets)
    expect(status).to eq(200), body[0, 300]
    expect($wash_out_budget_calls.last['items'].map { |h| h['sku'] }).to eq((0...300).map { |i| "s#{i}" })
  end

  it 'still resolves one reference into a large legitimate message' do
    status, body, = post('<ns:id>u</ns:id><ns:item href="#i"/>' + ('<ns:items><ns:sku>k</ns:sku></ns:items>' * 3000),
                         '<i id="i"><sku>s1</sku></i>')
    expect(status).to eq(200), body[0, 300]
    expect($wash_out_budget_calls.last['item']).to eq('sku' => 's1')
    expect($wash_out_budget_calls.last['items'].size).to eq 3000
  end
end
