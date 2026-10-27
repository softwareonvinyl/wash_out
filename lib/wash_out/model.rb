module WashOut
  module Model
    def wash_out_columns
      columns_hash
    end

    # Column types published (and read) as another simple type. Any other type
    # requests cannot be read into (json, uuid, inet, enum, ...) is published as
    # xsd:string and reaches the app as the text that was sent.
    COLUMN_TYPES = {
      :text      => :string,
      :float     => :double,
      :decimal   => :double,
      :timestamp => :string,
      :binary    => :base64Binary
    }.freeze

    def wash_out_param_map
      map = {}

      wash_out_columns.each do |key, column|
        type = column.type
        type = COLUMN_TYPES[type] if COLUMN_TYPES.has_key?(type)
        type = :string unless WashOut::Param::LOADABLE_TYPES.include?(type.to_s)
        map[key] = type
      end

      map
    end

    def wash_out_param_name(*args)
      return name.underscore
    end
  end
end