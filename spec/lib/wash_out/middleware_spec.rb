require 'spec_helper'
require 'wash_out/middleware'
require 'rexml/document'

describe WashOut::Middleware do
  let(:error) do
    begin
      REXML::Document.new '<hi>'
    rescue REXML::ParseException => e
      e
    end
  end

  # WashOut::Router answers unparseable request bodies itself, so a REXML error
  # that reaches the middleware comes from server code and must not be turned
  # into a Client fault (or swallowed).
  it 'lets REXML errors from server code propagate, with or without SOAPAction' do
    app = described_class.new(->(_env) { raise error })
    expect { app.call({}) }.to raise_exception(REXML::ParseException)
    expect { app.call('HTTP_SOAPACTION' => 'x') }.to raise_exception(REXML::ParseException)
  end

  it 'passes responses through' do
    app = described_class.new(->(_env) { [200, {}, ['ok']] })
    expect(app.call({})).to eq [200, {}, ['ok']]
  end
end
