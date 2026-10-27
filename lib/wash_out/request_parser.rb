require 'nori'
require 'rexml/parsers/baseparser'
require 'rexml/text'
require 'rexml/document'

module WashOut
  # Nori, configured for untrusted SOAP requests.
  #
  # With the :rexml parser (the default) the document is read by
  # WashOut::RequestParser::RexmlReader, which builds the same tree as
  # Nori::Parser::REXML but checks limits while it reads, before Nori's
  # recursive tree conversion runs:
  #
  # * a DOCTYPE is rejected (SOAP 1.1 section 3: a SOAP message MUST NOT
  #   contain a Document Type Declaration);
  # * element nesting is capped at +max_depth+, and elements plus attributes
  #   at +max_elements+ (every element is a live node until the end);
  # * the document has exactly one root element;
  # * text and attribute values must be valid UTF-8 made of XML 1.0
  #   characters (no NUL or other C0 controls from character references).
  #
  # Violations raise RequestParser::Error. Other parsers (:nokogiri) are used
  # as Nori ships them; libxml2 applies its own depth and character limits.
  class RequestParser < ::Nori
    class Error < StandardError; end

    DEFAULT_MAX_DEPTH    = 100
    DEFAULT_MAX_ELEMENTS = 100_000
    # XML whitespace only: String#strip would also drop NUL and other controls.
    LEADING_SPACE  = /\A[ \t\r\n]+/
    TRAILING_SPACE = /[ \t\r\n]+\z/
    # In any ASCII-compatible encoding these bytes only ever stand for C0
    # controls other than tab/LF/CR. REXML reads VT and FF as markup whitespace,
    # so they are checked in the raw document. Other characters (U+FFFE,
    # U+FFFF, ...) are checked after decoding, wherever they can occur.
    RAW_INVALID_BYTES = /[\x00-\x08\x0B\x0C\x0E-\x1F]/n

    def initialize(options = {}, max_depth: nil, max_elements: nil)
      @max_depth    = (max_depth || DEFAULT_MAX_DEPTH).to_i
      @max_elements = (max_elements || DEFAULT_MAX_ELEMENTS).to_i
      super(options)
    end

    # Overrides Nori's public #parse rather than a private Nori hook, so a
    # change in how Nori finds its parser cannot route :rexml requests around
    # RexmlReader and its checks.
    def parse(xml)
      return super unless @options[:parser].to_s == 'rexml'

      xml = xml.scrub if @options[:scrub_xml]
      cleaned = xml.sub(LEADING_SPACE, '').sub(TRAILING_SPACE, '')
      return {} if cleaned.empty?
      if !utf16?(cleaned) && cleaned.b.match?(RAW_INVALID_BYTES)
        raise Error, 'SOAP message contains characters that are not allowed in XML'
      end

      RexmlReader.new(@max_depth, @max_elements).parse(cleaned, @options)
    end

    # UTF-16 bodies (BOM, or a NUL next to the first '<') are checked after
    # REXML decodes them.
    def utf16?(xml)
      head = xml.b[0, 2]
      ["\xFE\xFF".b, "\xFF\xFE".b, "\x00<".b, "<\x00".b].include?(head)
    end

    class RexmlReader
      # Anything outside the XML 1.0 Char production.
      INVALID_XML_CHAR = /[^\t\n\r\u{20}-\u{D7FF}\u{E000}-\u{FFFD}\u{10000}-\u{10FFFF}]/

      def initialize(max_depth, max_elements = DEFAULT_MAX_ELEMENTS)
        @max_depth    = max_depth
        @max_elements = max_elements
      end

      def parse(xml, options)
        stack       = []
        parser      = ::REXML::Parsers::BaseParser.new(xml)
        nodes       = 0
        root_closed = false

        loop do
          event = parser.pull
          case event[0]
          when :end_document
            break
          when :xmldecl
            event[1..].each { |value| checked(value.to_s) if value }
          when :start_doctype
            raise Error, 'DOCTYPE is not allowed in a SOAP message'
          when :start_element
            raise Error, 'SOAP message has more than one root element' if root_closed
            raise Error, 'SOAP message is nested too deeply' if stack.size >= @max_depth
            nodes += 1 + event[2].size
            raise Error, 'SOAP message has too many elements' if nodes > @max_elements
            attributes = {}
            event[2].each { |name, value| attributes[name] = checked(::REXML::Text.unnormalize(value)) }
            stack.push ::Nori::XMLUtilityNode.new(options, event[1], attributes)
          when :end_element
            if stack.size > 1
              node = stack.pop
              stack.last.add_node(node)
            else
              root_closed = true
            end
          when :text, :cdata
            raw  = event[0] == :text ? ::REXML::Text.unnormalize(event[1]) : event[1]
            text = checked(raw)
            next if stack.empty? || text.strip.empty?
            raise Error, 'SOAP message has content after its root element' if root_closed
            nodes += 1
            raise Error, 'SOAP message has too many elements' if nodes > @max_elements
            stack.last.add_node(text)
          when :comment
            checked(event[1].to_s)
          when :processing_instruction
            checked(event[1].to_s)
            checked(event[2].to_s)
          end
        end

        stack.empty? ? {} : stack.pop.to_hash
      end

      private

      def checked(text)
        unless text.valid_encoding? && !text.match?(INVALID_XML_CHAR)
          raise Error, 'SOAP message contains characters that are not allowed in XML'
        end
        text
      end
    end
  end
end
