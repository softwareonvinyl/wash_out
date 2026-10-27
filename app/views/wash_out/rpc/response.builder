xml.instruct!
opts = { "xmlns:soap" => 'http://schemas.xmlsoap.org/soap/envelope/', "xmlns:#{@prefix}" => @namespace }
@namespaces.each { |obj| opts.merge!(obj) }

# Declared on each response element (the fork's layout since 604bca7), so the
# xsi:type / xsi:nil attributes inside are always bound.
schema_ns = { "xmlns:xsd" => 'http://www.w3.org/2001/XMLSchema',
              "xmlns:xsi" => 'http://www.w3.org/2001/XMLSchema-instance' }

xml.tag! "soap:Envelope", opts do
  if !header.nil?
    xml.tag! "soap:Header" do
      xml.tag! "#{@prefix}:#{@action_spec[:response_tag]}", schema_ns do
        wsdl_data xml, header
      end
    end
  end
  xml.tag! "soap:Body" do
    xml.tag! "#{@prefix}:#{@action_spec[:response_tag]}", schema_ns do
      wsdl_data xml, result
    end
  end
end
