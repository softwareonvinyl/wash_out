module WashOut
  # Resolves SOAP 1.1 section 5 multi-reference accessors: an element that
  # carries href="#X" is replaced by the element that carries id="X".
  #
  # This runs before any controller code, so it is bounded:
  #
  # * ids are indexed in one linear pass;
  # * a "#..." href with no matching id, an href to an id used twice, and
  #   circular references raise MultiRef::Error;
  # * the resolved tree is built fresh, so accessors that share a target never
  #   alias the same Hash;
  # * every container visited costs 1, and every container copied also costs
  #   its number of entries, from a budget of max(DEFAULT_MAX_NODES,
  #   INPUT_FACTOR x entries in the message): the resolved tree is at most a
  #   constant factor larger than the input however references are shared;
  # * element nesting is capped (an Array of repeated elements is not a level).
  #
  # * text reached through hrefs is charged too (bytes, against
  #   max(DEFAULT_MAX_TEXT, INPUT_FACTOR x text in the message)), so one long
  #   text cannot be referenced thousands of times.
  #
  # Independent elements (SOAP 1.1 section 5: the Body-level multiRef siblings
  # that rpc/encoded clients such as Axis and .NET write, each referenced by
  # href) are expanded where they are referenced, not also in place: pass the
  # Body as +independent_in+ and the operation element's key as +keep+.
  #
  # Simple-value targets (an element holding only text, as Axis-style encoders
  # write for soapenc:string / soapenc:int) resolve to that text.
  #
  # Messages without any href are returned untouched.
  class MultiRef
    class Error < StandardError; end

    # Budget, in entries (Hash pairs, Array items, plus 1 per container).
    DEFAULT_MAX_NODES = 50_000
    # Legitimate messages that reference each value once resolve at about 1x;
    # the factor only matters when references are shared.
    INPUT_FACTOR      = 8
    DEFAULT_MAX_DEPTH = 100
    # Text floor, in bytes; the router passes max_request_size. Text is not
    # copied (references share one String), so this only stops one long text
    # being handed to the app many times over.
    DEFAULT_MAX_TEXT  = 1_048_576

    def self.resolve(data, max_nodes: nil, max_depth: nil, max_text: nil, independent_in: nil, keep: nil)
      new(max_nodes, max_depth).resolve(data, max_text: max_text, independent_in: independent_in, keep: keep)
    end

    # Generic form used by Dispatcher.deep_replace_href: +targets+ maps raw
    # href values to replacement values.
    def self.replace(data, targets, max_nodes: nil, max_depth: nil)
      new(max_nodes, max_depth).replace(data, targets)
    end

    def initialize(max_nodes = nil, max_depth = nil)
      @max_nodes = (max_nodes || DEFAULT_MAX_NODES).to_i
      @max_depth = (max_depth || DEFAULT_MAX_DEPTH).to_i
    end

    def resolve(data, max_text: nil, independent_in: nil, keep: nil)
      return data unless container?(data)

      @targets    = {}
      @dupes      = {}
      @referenced = {}
      @hrefs      = 0
      @size       = 0
      @text       = 0
      index(data, 0)
      return data if @hrefs.zero?

      @independent_in = independent_in
      @keep           = keep
      @text_budget    = [(max_text || DEFAULT_MAX_TEXT).to_i, INPUT_FACTOR * @text].max
      expand_all(data, [@max_nodes, INPUT_FACTOR * @size].max)
    end

    def replace(data, targets)
      @targets = targets
      @dupes   = {}
      expand_all(data, @max_nodes)
    end

    private

    def expand_all(data, budget)
      @budget = budget
      expand(data, 0, {})
    end

    def container?(value)
      value.is_a?(Hash) || value.is_a?(Array)
    end

    def check_depth!(depth)
      raise Error, 'SOAP message is nested too deeply' if depth > @max_depth
    end

    # One pass: measure the message, count hrefs, index elements with an id.
    # Depth counts elements: the members of an Array (repeated elements) sit
    # at the Array's own level.
    def index(node, depth)
      check_depth!(depth)
      @size += 1 + node.size

      if node.is_a?(Hash)
        if node.key?(:@href)
          @hrefs += 1
          @referenced[node[:@href]] = true
        end
        register("##{node[:@id]}", node) if node.key?(:@id)
        node.each_value { |v| visit(v, depth + 1) }
      else
        node.each { |v| visit(v, depth) }
      end
    end

    def visit(value, depth)
      if container?(value)
        index(value, depth)
      else
        @text += value.bytesize if value.is_a?(String)
        register("##{simple_target_id(value)}", value) if simple_target_id(value)
      end
    end

    # A Body-level element (or repeated elements) that some href points at.
    def independent?(value)
      if value.is_a?(Array)
        !value.empty? && value.all? { |item| independent?(item) }
      elsif value.is_a?(Hash)
        value.key?(:@id) && @referenced.key?("##{value[:@id]}")
      else
        id = simple_target_id(value)
        !id.nil? && @referenced.key?("##{id}")
      end
    end

    # Text-only element with an id attribute (Nori::StringWithAttributes).
    def simple_target_id(value)
      return nil unless value.is_a?(String) && value.respond_to?(:attributes)
      attributes = value.attributes
      attributes['id'] if attributes.is_a?(Hash)
    end

    def register(key, node)
      # Only an error if an href actually points at it (see #expand).
      @dupes[key] = true if @targets.key?(key)
      @targets[key] ||= node
    end

    def expand(node, depth, active)
      unless container?(node)
        if node.is_a?(String) && !active.empty? && @text_budget
          raise Error, 'SOAP multiRef text limit exceeded' if (@text_budget -= node.bytesize) < 0
        end
        return node
      end
      check_depth!(depth)
      raise Error, 'SOAP multiRef expansion limit exceeded' if (@budget -= 1) < 0

      if node.is_a?(Hash) && node.key?(:@href)
        href = node[:@href]
        if @targets.key?(href)
          raise Error, 'Ambiguous SOAP href' if @dupes.key?(href)
          raise Error, 'Circular SOAP href' if active.key?(href)
          active[href] = true
          begin
            return expand(@targets[href], depth + 1, active)
          ensure
            active.delete(href)
          end
        elsif href.is_a?(String) && href.start_with?('#')
          raise Error, 'Unresolved SOAP href'
        end
        # Any other href (an absolute URI, say) is not a SOAP-encoding
        # accessor: keep the element and never dereference it.
      end

      # This container is copied: pay for every entry before copying it.
      raise Error, 'SOAP multiRef expansion limit exceeded' if (@budget -= node.size) < 0
      return node.map { |v| expand(v, depth, active) } if node.is_a?(Array)

      if @independent_in && node.equal?(@independent_in)
        # Body: keep referenced independent elements as they are; they are
        # expanded where their hrefs point.
        return node.each_with_object({}) do |(k, v), out|
          out[k] = k != @keep && independent?(v) ? v : expand(v, depth + 1, active)
        end
      end

      node.each_with_object({}) { |(k, v), out| out[k] = expand(v, depth + 1, active) }
    end
  end
end
