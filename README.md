# WashOut

WashOut is a gem that greatly simplifies creation of SOAP service providers.

[![Gem Version](https://badge.fury.io/rb/wash_out.png)](http://badge.fury.io/rb/wash_out)
[![Travis CI](https://secure.travis-ci.org/inossidabile/wash_out.png)](https://travis-ci.org/inossidabile/wash_out)
[![Code Climate](https://codeclimate.com/github/inossidabile/wash_out.png)](https://codeclimate.com/github/inossidabile/wash_out)

But if you have a chance, please [http://stopsoap.com/](http://stopsoap.com/).

## Compatibility

Rails 4.0 and higher is tested. Code is known to work with earlier versions but we don't bother testing outdated versions anymore - give it a try if you are THAT unlucky.

## Installation

In your Gemfile, add this line:

    gem 'wash_out'

Please read [release details](https://github.com/inossidabile/wash_out/releases) if you are upgrading. We break backward compatibility between large ticks but you can expect it to be specified at release notes.

## Usage

A SOAP endpoint in WashOut is simply a Rails controller which includes the module WashOut::SOAP. Each SOAP
action corresponds to a certain controller method; this mapping, as well as the argument definition, is defined
by [soap_action][] method. Check the method documentation for complete info; here, only a few examples will be
demonstrated.

  [soap_action]: http://rubydoc.info/gems/wash_out/WashOut/SOAP/ClassMethods#soap_action-instance_method

```ruby
# app/controllers/rumbas_controller.rb
class RumbasController < ApplicationController
  soap_service namespace: 'urn:WashOut'

  # Simple case
  soap_action "integer_to_string",
              :args   => :integer,
              :return => :string
  def integer_to_string
    render :soap => params[:value].to_s
  end

  soap_action "concat",
              :args   => { :a => :string, :b => :string },
              :return => :string
  def concat
    render :soap => (params[:a] + params[:b])
  end

  # Complex structures
  soap_action "AddCircle",
              :args   => { :circle => { :center => { :x => :integer,
                                                     :y => :integer },
                                        :radius => :double } },
              :return => nil, # [] for wash_out below 0.3.0
              :to     => :add_circle
  def add_circle
    circle = params[:circle]

    raise SOAPError, "radius is too small" if circle[:radius] < 3.0

    Circle.new(circle[:center][:x], circle[:center][:y], circle[:radius])

    render :soap => nil
  end

  # Arrays
  soap_action "integers_to_boolean",
              :args => { :data => [:integer] },
              :return => [:boolean]
  def integers_to_boolean
    render :soap => params[:data].map{|i| i > 0}
  end

  # Params from XML attributes;
  # e.g. for a request to the 'AddCircle' action:
  #   <soapenv:Envelope>
  #     <soapenv:Body>
  #       <AddCircle>
  #         <Circle radius="5.0">
  #           <Center x="10" y="12" />
  #         </Circle>
  #       </AddCircle>
  #     </soapenv:Body>
  #   </soapenv:Envelope>
  soap_action "AddCircle",
              :args   => { :circle => { :center => { :@x => :integer,
                                                     :@y => :integer },
                                        :@radius => :double } },
              :return => nil, # [] for wash_out below 0.3.0
              :to     => :add_circle
  def add_circle
    circle = params[:circle]
    Circle.new(circle[:center][:x], circle[:center][:y], circle[:radius])

    render :soap => nil
  end

  # With a customised input tag name, in case params are wrapped;
  # e.g. for a request to the 'IntegersToBoolean' action:
  #   <soapenv:Envelope>
  #     <soapenv:Body>
  #       <MyRequest>  <!-- not <IntegersToBoolean> -->
  #         <Data>...</Data>
  #       </MyRequest>
  #     </soapenv:Body>
  #   </soapenv:Envelope>
  soap_action "integers_to_boolean",
              :args => { :my_request => { :data => [:integer] } },
              :as => 'MyRequest',
              :return => [:boolean]

  # You can use all Rails features like filtering, too. A SOAP controller
  # is just like a normal controller with a special routing.
  before_filter :dump_parameters
  def dump_parameters
    Rails.logger.debug params.inspect
  end
  
  
  # Rendering SOAP headers
  soap_action "integer_to_header_string",
              :args   => :integer,
              :return => :string,
              :header_return => :string
  def integer_to_header_string
    render :soap => params[:value].to_s, :header => (params[:value]+1).to_s
  end
  
  # Reading SOAP Headers
  # This is different than normal SOAP params, because we don't specify the incoming format of the header,
  # but we can still access it through `soap_request.headers`.  Note that the values are all strings or hashes.
  soap_action "AddCircleWithHeaderRadius",
              :args   => { :circle => { :center => { :x => :integer,
                                                     :y => :integer } } },
              :return => nil, # [] for wash_out below 0.3.0
              :to     => :add_circle
  # e.g. for a request to the 'AddCircleWithHeaderRadius' action:
  #   <soapenv:Envelope>
  #     <soap:Header>
  #       <radius>12345</radius>
  #     </soap:Header>
  #     <soapenv:Body>
  #       <AddCircle>
  #         <Circle radius="5.0">
  #           <Center x="10" y="12" />
  #         </Circle>
  #       </AddCircle>
  #     </soapenv:Body>
  #   </soapenv:Envelope>
  def add_circle_with_header_radius
    circle = params[:circle]
    radius = soap_request.headers[:radius]
    raise SOAPError, "radius must be specified in the SOAP header" if radius.blank?
    radius = radius.to_f
    raise SOAPError, "radius is too small" if radius < 3.0

    Circle.new(circle[:center][:x], circle[:center][:y], radius)

    render :soap => nil
  end
  
end
```

```ruby
# config/routes.rb
WashOutSample::Application.routes.draw do
  wash_out :rumbas
end
```

In such a setup, the generated WSDL may be queried at path `/rumbas/wsdl`. So, with a
gem like Savon, a request can be done using this path:

```ruby
require 'savon'

client = Savon::Client.new(wsdl: "http://localhost:3000/rumbas/wsdl")

client.operations # => [:integer_to_string, :concat, :add_circle]

result = client.call(:concat, message: { :a => "123", :b => "abc" })

# actual wash_out
result.to_hash # => {:concat_reponse => {:value=>"123abc"}}

# wash_out below 0.3.0 (and this is malformed response so please update)
result.to_hash # => {:value=>"123abc"}
```

## Reusable types

Basic inline types definition is fast and furious for the simple cases. You have an option to describe SOAP types
inside separate classes for the complex ones. Here's the way to do that:

```ruby
class Fluffy < WashOut::Type
  map :universe => {
        :name => :string,
        :age  => :integer
      }
end

class FluffyContainer < WashOut::Type
  type_name 'fluffy_con'
  map :fluffy => Fluffy
end
```

To use defined type inside your inline declaration, pass the class instead of type symbol (`:fluffy => Fluffy`).

Note that WashOut extends the `ActiveRecord` so every model you use is already a WashOut::Type and can be used
inside your interface declarations.

## WSSE Authentication

WashOut provides two mechanism for WSSE Authentication. 

### Static Authentication

You can configure the service to validate against a username and password with the following configuration:

```ruby
soap_service namespace: "wash_out", wsse_username: "username", wsse_password: "password"
```

With this mechanism, all the actions in the controller will be authenticated against the specified username and password. If you need to authenticate different users, you can use the dynamic mechanism described below.

### Dynamic Authentication

Dynamic authentication allows you to process the username and password any way you want, with the most common case being authenticating against a database. The configuration option for this mechanism is called `wsse_auth_callback`:

```ruby
soap_service namespace: "wash_out", wsse_auth_callback: ->(username, password, nonce, timestamp) {
  return !User.find_by(username: username).authenticate(password).blank?
}
```

The callback must accept four arguments; any other callable makes every request fail rather than switching authentication off. WSSE is required as soon as any `wsse_*` option is set. Digests are checked over the `Created` text exactly as sent, within 5 minutes either side of the server clock. There is no nonce cache, so a captured digest can be replayed within that window.

Keep in mind that the password may already be hashed by the SOAP client, so you would have to check against that condition too as per [spec](http://www.oasis-open.org/committees/download.php/16782/wss-v1.1-spec-os-UsernameTokenProfile.pdf)

## Configuration

Use `config.wash_out...` inside your environment configuration to setup WashOut globally.
To override the values on a specific controller just add an override as part of the arguments to the `soap_service` method.

Available properties are:

* **parser**: XML parser to use, `:rexml` (default) or `:nokogiri`. Only `:rexml` gets the request checks described under *Request limits*; use it for untrusted callers.
* **wsdl_style**: sets WSDL style. Supported values are: 'document' and 'rpc'.
* **catch_xml_errors**: kept for compatibility and no longer changes anything. Requests that cannot be parsed always get a Client SOAP fault from the router.
* **namespace**: SOAP namespace to use. Default is `urn:WashOut`.
* **prefix**: namespace prefix used in responses and the WSDL. Default is `tns`. It must be an XML name other than `soap`, `soap-enc`, `xsd`, `xsi`, `wsdl` or `xml*`.
* **namespaces**: extra namespace declarations for responses, e.g. `[{ 'xmlns:shar' => 'urn:...' }]`. They must not rebind the service prefix, `tns`, or a reserved prefix.
* **snakecase_input**: Determines if WashOut should modify parameters keys to snakecase. Default is `false`.
* **camelize_wsdl**: Determines if WashOut should camelize types within WSDL and responses. Supports `true` for CamelCase and `:lower` for camelCase. Default is `false`.
* **max_request_size**: largest request body in bytes. Default `1_048_576` (1 MiB); `nil` disables it.
* **max_nesting_depth**: deepest element nesting accepted. Default `100`, at most `200`.
* **max_elements**: most elements, attributes and text nodes accepted in one request. Default `100_000`.
* **endpoint_base_url**: origin advertised as the WSDL `soap:address`, e.g. `"https://api.example.com"`. Without it the address follows the request's Host / X-Forwarded-Host header. Set it in production.

A config built by `soap_service` is frozen; call `soap_service` again to change it.

### Request limits

The router checks every request before any controller code runs, so before your own authentication. It answers with a `Client` SOAP fault, without running controller callbacks, when:

* the method is not POST, or the body is larger than `max_request_size`;
* the XML has a DOCTYPE, more than one root element, nesting deeper than `max_nesting_depth`, more than `max_elements` elements, attributes and text nodes, characters outside XML 1.0 (anywhere in a UTF-8 document; in text and attribute values for UTF-16), or bytes that are not valid in its encoding;
* there is no Envelope with a Body, Header or Body is spelled twice, the rpc operation element holds text or repeats, or the operation is not declared (in rpc style with `soap_action_routing`, a Body that has elements but none named after the SOAPAction is refused too);
* a SOAP-encoded `href` that is followed is circular, dangling or points at a duplicated id, or an `href` sits on the Envelope, Header, Body, the rpc operation element or a document-style message part;
* resolving references would build more than max(50,000 entries, 8 x the entries sent), or hand on more text than max(`max_request_size`, 8 x the text sent). Rpc/encoded Body-level multiRef elements count once, where they are referenced.

UTF-8 and UTF-16 (with a byte order mark) requests are accepted.

Arguments are typed strictly from the WSDL: `xsd:int` and `xsd:long` ranges, decimal or exponent doubles, booleans `true`, `false`, `1` and `0`. A plain `type="..."` attribute is ignored, and strings arrive exactly as sent. Child or repeated elements where a single simple value is declared are refused. Faults name the element path, for example `Invalid SOAP parameter 'PO/LineItemArray/LineItem[2]/unitPrice' format`, and the reason is logged at info level. wash_out never logs request bodies, and it drops form-typed bodies on the `/action` and `/wsdl` routes before Rails logs parameters. Middleware that runs before routing, such as `Rack::MethodOverride`, can still read a form-typed body, so cap request sizes in the web server too.

Still lenient, as in 0b7d787: `:date`, `:datetime` and `:time` arguments are parsed with Ruby's `Date.parse`-style parsing, `:base64Binary` ignores characters outside the alphabet, and REXML does not enforce every well-formedness rule: an undeclared entity reference (`&foo;`), a bare `&`, `<` in an attribute value or `]]>` in text reach the app as text. Return values typed `:base64Binary` are written as given, so encode them yourself.

### Camelization

Note that WSDL camelization will affect method names but only if they were given as a symbol:

```ruby
soap_action :foo  # this will be affected
soap_action "foo" # this will be passed as is
```

## Maintainers

* Boris Staal, [@inossidabile](http://staal.io)

## Contributors (in random order)

* Mikael Henriksson, [@mhenrixon](http://twitter.com/mhenrixon)
* Björn Nilsson [@Bjorn-Nilsson](https://github.com/Bjorn-Nilsson)
* Tobias Bielohlawek [@rngtng](https://github.com/rngtng)
* Francesco Negri [@dhinus](https://github.com/dhinus)
* Edgars Beigarts [@ebeigarts](https://github.com/ebeigarts)
* [Exad](https://github.com/exad) [@wknechtel](https://github.com/wknechtel) and [@☈king](https://github.com/rking)
* Mark Goris [@gorism](https://github.com/gorism)
* ... and [others](https://github.com/inossidabile/wash_out/graphs/contributors)

## License

It is free software, and may be redistributed under the terms of MIT license.

[![Bitdeli Badge](https://d2weczhvl823v0.cloudfront.net/inossidabile/wash_out/trend.png)](https://bitdeli.com/free "Bitdeli Badge")
