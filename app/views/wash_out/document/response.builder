xml.instruct!
opts = { "xmlns:soap" => 'http://schemas.xmlsoap.org/soap/envelope/',
         "xmlns:xsd" => 'http://www.w3.org/2001/XMLSchema',
         "xmlns:tns" => @namespace }
# namespace_everything prefixes elements with the configured prefix.
opts["xmlns:#{@prefix}"] ||= @namespace if @prefix.present?
@namespaces.each { |obj| opts.merge!(obj) }

xml.tag! "soap:Envelope", opts do
  if !header.nil?
    xml.tag! "soap:Header" do
      xml.tag! "tns:#{@action_spec[:response_tag]}" do
        wsdl_data xml, header
      end
    end
  end
  xml.tag! "soap:Body" do
    xml.tag! "tns:#{@action_spec[:response_tag]}" do
      wsdl_data xml, result
    end
  end
end
