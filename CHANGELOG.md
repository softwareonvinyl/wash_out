# Changelog

## 0.12.15 (sov fork): security hardening

Request handling (all before controller code runs):

* Request bodies are limited (`max_request_size`, `max_nesting_depth`, `max_elements`), parsed once, and may not contain a DOCTYPE, a second root element or non-XML characters.
* Requests that are not POST, cannot be parsed, have the wrong shape or name an undeclared operation get a Client fault from the router itself, without running controller callbacks. Only the error class or a fixed message is logged, never the body.
* Form-typed bodies sent to `/action` or `/wsdl` are dropped before Rails logs parameters (middleware such as Rack::MethodOverride runs earlier and can still read them).
* SOAP-encoded href/id references are bounded: cycles, dangling and ambiguous references are refused. Expansion is charged per entry (max(50,000, 8 x the entries sent)) and per byte of text reached (max(max_request_size, 8 x the text sent)). Rpc Body-level multiRef elements are expanded only where referenced. Document-style message parts may not carry an href.
* UTF-16 requests with a byte order mark are accepted.
* A plain `type="..."` attribute is ignored, and Nori's advanced typecasting is off: strings arrive verbatim.

Arguments:

* `:integer` and `:long` must be whole numbers within xsd:int and xsd:long. `:double` must be a finite decimal or exponent. `:boolean` accepts true, false, 1 and 0. Other values get a Client fault naming the element path.
* Child or repeated elements where a single simple value is declared are refused. An empty element that carries only attributes is read as empty.
* Argument types that requests cannot be read into (`:text`, `:json`, ...) and `@type` argument attributes are refused when `soap_action` is defined. `WashOut::Model` publishes every column as a readable type (binary as base64Binary, json/uuid/... as string), so model-typed arguments keep working.

WSSE:

* Credentials are compared in constant time. Digests are checked over the `Created` text as sent, within 5 minutes either side. A partial configuration fails closed. The callback must take four arguments. `WSSE_TOKEN` holds only the fields that were checked, under the caller's spelling.

Responses, WSDL and configuration:

* Symbol values are written as text. A Hash or Array in a simple-type slot raises `ProgrammerError`. Faults declare `xsd`, header responses declare `xsi`/`xsd`, and request faults use `Client`.
* `endpoint_base_url` pins the WSDL `soap:address`. `Router.url` raises `RouteNotFound` instead of returning the route table.
* Each controller has its own frozen config. Subclasses no longer change their parent's config, and inherited operations follow the subclass's prefix. `prefix`, `namespaces`, `wsdl_style`, `parser` and the limits are validated. wash_out's internal methods are no longer controller actions. Route options no longer leak into later routes.
* `catch_xml_errors` / `WashOut::Middleware` no longer change anything, because the router handles unparseable requests.
* `Dispatcher.deep_replace_href` now raises `MultiRef::Error` for circular or dangling references and when the budget is exceeded.

Dependencies:

* nori >= 2.7 and < 3, rexml >= 3.4.2, builder, actionpack and railties >= 7.1, base64. `soap_request` returns a Struct instead of an OpenStruct. Active Record is extended via `on_load`, so `require 'wash_out'` no longer loads it early.

## Not Supported!

This is here for historical reasons. Please refer to [Releases](https://github.com/inossidabile/wash_out/releases) page to get actual information.

## 0.7.1

* Parser switcher [@inossidabile][]
* Namespaces support patched [@inossidabile][]

## 0.7.0

* WSDL Document mode support [@gorism][]

## 0.6.0

* Switched to Savon2 family [@inossidabile][]
* Main spec refactored greatly [@inossidabile][]

## 0.5.4

* Ability to manually specify `response_tag` for `soap_action` [@inossidabile][]

## 0.5.2

* .NET-compliant response tags [@ebeigarts][]
* Tiny fixes [@ebeigarts][]

## 0.5.1

* Better routing points [@inossidabile][]

## 0.5.0

* WSSE password authentication [@dhinus][]
* Ruby 1.8 compatibility restores [@dhinus][]

## 0.4.2

* SOAP hrefs are now supported [@inossidabile][]
* Better camelization: reusable types and methods are now supported [@inossidabile][]

## 0.4.1

* .NET-compliant :integer type WSDL [@inossidabile][]

## 0.4.0

* Better content-type for the response (#33) [@inossidabile][]
* Date type support (#18) [@inossidabile][]
* Avoid duplication of inner types [@inossidabile][]
* Output camelization support [@inossidabile][]
* External types declaration support (#21, #41) [@inossidabile][]

## 0.3.7

* Better empty parameters handling (#26, #30) [@rngtng][]

## 0.3.6

* Unicorn stream reading bug (#20)
* .NET minOccurs/maxOccurs basic WSDL compatibility (#22, #23)

## 0.3.5

* Very evil thread-safety bug fixed. You are encouraged to never use anything below this version.

## 0.3.4

* WSDL generation fixed to support complex structures for return values
* Configuration moved to OrderedOptions with proper Engine binding
* `snakecase` configuration directive added: if set to false, wash_out won't modify params keys

## 0.3.3

* Tiny fixes in wash_out behavior with inline arrays (#11, #12)
* Ability to change namespace

## 0.3.2

* WashOut doesn't check existance of parameters anymore you should do it yourself from now
* Proper handling of blank parameters (#10)
* Proper handling of complex structures inside arrays (#9)
* Response performance improved

## 0.3.1

* Support of complex structures inside array
* Better Nori handling (no more dependency on Savon hijacking)

## 0.3.0

* The syntax for empty set (no input params or output params) changed from [] to nil.
* SOAP response format improved. All results are now wrapped into tns:messages instead of soap:Body.
* Arrays (minOccurs/maxOccurs) are now supported with `:foo => [:integer]` syntax.

[@inossidabile]: http://staal.io
[@rngtng]: https://github.com/rngtng
[@dhinus]: https://github.com/dhinus
[@ebeigarts]: https://github.com/ebeigarts
[@gorism]: https://github.com/gorism