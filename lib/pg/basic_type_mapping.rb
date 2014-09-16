#!/usr/bin/env ruby

require 'pg' unless defined?( PG )

module PG::BasicTypeRegistry
	# An instance of this class stores the coders that should be used for a given wire format (text or binary)
	# and type cast direction (encoder or decoder).
	class CoderMap
		# Hash of text types that don't require quotation, when used within composite types.
		#   type.name => true
		DONT_QUOTE_TYPES = %w[
			int2 int4 int8
			float4 float8
			oid
			bool
			date timestamp timestamptz
		].inject({}){|h,e| h[e] = true; h }

		def initialize(result, coders_by_name, format, arraycoder)
			coder_map = {}

			ranges, nodes = result.partition { |row| row['typinput'] == 'range_in' }
			leaves, nodes = nodes.partition { |row| row['typelem'] == '0' }
			arrays, nodes = nodes.partition { |row| row['typinput'] == 'array_in' }

			# populate the enum types
			enums, leaves = leaves.partition { |row| row['typinput'] == 'enum_in' }
	# 		enums.each do |row|
	# 			coder_map[row['oid'].to_i] = OID::Enum.new
	# 		end

			# populate the base types
			leaves.find_all { |row| coders_by_name.key?(row['typname']) }.each do |row|
				coder = coders_by_name[row['typname']].dup
				coder.oid = row['oid'].to_i
				coder.name = row['typname']
				coder.format = format
				coder_map[coder.oid] = coder
			end

			records_by_oid = result.group_by { |row| row['oid'] }

			# populate composite types
	# 		nodes.each do |row|
	# 			add_oid row, records_by_oid, coder_map
	# 		end

			if arraycoder
				# populate array types
				arrays.each do |row|
					elements_coder = coder_map[row['typelem'].to_i]
					next unless elements_coder

					coder = arraycoder.new
					coder.oid = row['oid'].to_i
					coder.name = row['typname']
					coder.format = format
					coder.elements_type = elements_coder
					coder.needs_quotation = !DONT_QUOTE_TYPES[elements_coder.name]
					coder_map[coder.oid] = coder
				end
			end

			# populate range types
	# 		ranges.find_all { |row| coder_map.key? row['rngsubtype'].to_i }.each do |row|
	# 			subcoder = coder_map[row['rngsubtype'].to_i]
	# 			range = OID::Range.new subcoder
	# 			coder_map[row['oid'].to_i] = range
	# 		end

			@coders = coder_map.values
			@coders_by_name = @coders.inject({}){|h, t| h[t.name] = t; h }
			@coders_by_oid = @coders.inject({}){|h, t| h[t.oid] = t; h }
		end

		attr_reader :coders
		attr_reader :coders_by_oid
		attr_reader :coders_by_name

		def coder_by_name(name)
			@coders_by_name[name]
		end

		def coder_by_oid(oid)
			@coders_by_oid[oid]
		end
	end

	private

	def supports_ranges?(connection)
		connection.server_version >= 90200
	end

	def build_coder_maps(connection)
		if supports_ranges?(connection)
			result = connection.exec <<-SQL
				SELECT t.oid, t.typname, t.typelem, t.typdelim, t.typinput, r.rngsubtype
				FROM pg_type as t
				LEFT JOIN pg_range as r ON oid = rngtypid
			SQL
		else
			result = connection.exec <<-SQL
				SELECT t.oid, t.typname, t.typelem, t.typdelim, t.typinput
				FROM pg_type as t
			SQL
		end

		[
			[0, :encoder, PG::TextEncoder::Array],
			[0, :decoder, PG::TextDecoder::Array],
			[1, :encoder, nil],
			[1, :decoder, nil],
		].inject([]) do |h, (format, direction, arraycoder)|
			h[format] ||= {}
			h[format][direction] = CoderMap.new result, CODERS_BY_NAME[format][direction], format, arraycoder
			h
		end
	end

	ValidFormats = { 0 => true, 1 => true }
	ValidDirections = { :encoder => true, :decoder => true }

	def check_format_and_direction(format, direction)
		raise(ArgumentError, "Invalid format value %p" % format) unless ValidFormats[format]
		raise(ArgumentError, "Invalid direction %p" % direction) unless ValidDirections[direction]
	end


	# The key of this hash maps to the `typname` column from the table.
	# encoder_map is then dynamically built with oids as the key and Type
	# objects as values.
	CODERS_BY_NAME = []

	# Register an OID type named +name+ with a typecasting encoder and decoder object in
	# +type+.  +name+ should correspond to the `typname` column in
	# the `pg_type` table.
	def self.register_type(format, name, encoder_class, decoder_class)
		CODERS_BY_NAME[format] ||= { encoder: {}, decoder: {} }
		CODERS_BY_NAME[format][:encoder][name] = encoder_class.new(name: name, format: format) if encoder_class
		CODERS_BY_NAME[format][:decoder][name] = decoder_class.new(name: name, format: format) if decoder_class
	end

	# Alias the +old+ type to the +new+ type.
	def self.alias_type(format, new, old)
		CODERS_BY_NAME[format][:encoder][new] = CODERS_BY_NAME[format][:encoder][old]
		CODERS_BY_NAME[format][:decoder][new] = CODERS_BY_NAME[format][:decoder][old]
	end

	register_type 0, 'int2', PG::TextEncoder::Integer, PG::TextDecoder::Integer
	alias_type    0, 'int4', 'int2'
	alias_type    0, 'int8', 'int2'
	alias_type    0, 'oid',  'int2'

# 	register_type 0, 'numeric', OID::Decimal.new
	register_type 0, 'text', PG::TextEncoder::String, PG::TextDecoder::String
	alias_type 0, 'varchar', 'text'
	alias_type 0, 'char', 'text'
	alias_type 0, 'bpchar', 'text'
	alias_type 0, 'xml', 'text'

# 	# FIXME: why are we keeping these types as strings?
# 	alias_type 'tsvector', 'text'
# 	alias_type 'interval', 'text'
# 	alias_type 'macaddr',  'text'
# 	alias_type 'uuid',     'text'
#
# 	register_type 'money', OID::Money.new
	# There is no PG::TextEncoder::Bytea, because it's simple and more efficient to send bytea-data
	# in binary format, either with PG::BinaryEncoder::Bytea or in Hash param format.
	register_type 0, 'bytea', nil, PG::TextDecoder::Bytea
	register_type 0, 'bool', PG::TextEncoder::Boolean, PG::TextDecoder::Boolean
# 	register_type 'bit', OID::Bit.new
# 	register_type 'varbit', OID::Bit.new
#
	register_type 0, 'float4', PG::TextEncoder::Float, PG::TextDecoder::Float
	alias_type 0, 'float8', 'float4'

	register_type 0, 'timestamp', PG::TextEncoder::TimestampWithoutTimeZone, PG::TextDecoder::TimestampWithoutTimeZone
	register_type 0, 'timestamptz', PG::TextEncoder::TimestampWithTimeZone, PG::TextDecoder::TimestampWithTimeZone
	register_type 0, 'date', PG::TextEncoder::Date, PG::TextDecoder::Date
# 	register_type 'time', OID::Time.new
#
# 	register_type 'path', OID::Text.new
# 	register_type 'point', OID::Point.new
# 	register_type 'polygon', OID::Text.new
# 	register_type 'circle', OID::Text.new
# 	register_type 'hstore', OID::Hstore.new
# 	register_type 'json', OID::Json.new
# 	register_type 'citext', OID::Text.new
# 	register_type 'ltree', OID::Text.new
#
# 	register_type 'cidr', OID::Cidr.new
# 	alias_type 'inet', 'cidr'



	register_type 1, 'int2', PG::BinaryEncoder::Int2, PG::BinaryDecoder::Integer
	register_type 1, 'int4', PG::BinaryEncoder::Int4, PG::BinaryDecoder::Integer
	register_type 1, 'int8', PG::BinaryEncoder::Int8, PG::BinaryDecoder::Integer
	alias_type    1, 'oid',  'int2'

	register_type 1, 'text', PG::BinaryEncoder::String, PG::BinaryDecoder::String
	alias_type 1, 'varchar', 'text'
	alias_type 1, 'char', 'text'
	alias_type 1, 'bpchar', 'text'
	alias_type 1, 'xml', 'text'

	register_type 1, 'bytea', PG::BinaryEncoder::Bytea, PG::BinaryDecoder::Bytea
	register_type 1, 'bool', PG::BinaryEncoder::Boolean, PG::BinaryDecoder::Boolean
	register_type 1, 'float4', nil, PG::BinaryDecoder::Float
	register_type 1, 'float8', nil, PG::BinaryDecoder::Float
end

# Simple set of rules for type casting common PostgreSQL types to Ruby.
#
# OIDs of supported type casts are not hard-coded in the sources, but are retrieved from the
# PostgreSQL's pg_type table in PG::BasicTypeMapForResults.new .
#
# Result values are type casted based on the type OID of the given result column.
#
# Higher level libraries will most likely not make use of this class, but use their
# own set of rules to choose suitable encoders and decoders.
#
# Example:
#   conn = PG::Connection.new
#   # Assign a default ruleset for type casts of input and output values.
#   conn.type_mapping = PG::BasicTypeMapping.new(conn)
#   # Execute a query.
#   res = conn.exec_params( "SELECT $1::INT", ['5'] )
#   # Retrieve and cast the result value. Value format is 0 (text) and OID is 20. Therefore typecasting
#   # is done by PG::TextDecoder::Integer internally for all value retrieval methods.
#   res.values  # => [[5]]
class PG::BasicTypeMapForResults < PG::TypeMapByOid
	include PG::BasicTypeRegistry

	def initialize(connection)
		@coder_maps = build_coder_maps(connection)

		# Populate TypeMapByOid hash with coders
		@coder_maps.map{|f| f[:decoder].coders }.flatten.each do |coder|
			add_coder(coder)
		end
	end
end

# Simple set of rules for type casting common Ruby types to PostgreSQL.
#
# OIDs of supported type casts are not hard-coded in the sources, but are retrieved from the
# PostgreSQL's pg_type table in PG::BasicTypeMapForQueries.new .
#
# Query params are type casted based on the MRI internal type of the given value.
#
# Higher level libraries will most likely not make use of this class, but use their
# own set of rules to choose suitable encoders and decoders.
#
# Example:
#   conn = PG::Connection.new
#   # Assign a default ruleset for type casts of input and output values.
#   conn.type_mapping_for_queries = PG::BasicTypeMapForQueries.new(conn)
#   # Execute a query. The Integer param value is typecasted internally by PG::BinaryEncoder::Int8.
#   # The format of the parameter is set to 1 (binary) and the OID of this parameter is set to 20 (int8).
#   res = conn.exec_params( "SELECT $1", [5] )
class PG::BasicTypeMapForQueries < PG::TypeMapByMriType
	include PG::BasicTypeRegistry

	def initialize(connection)
		@coder_maps = build_coder_maps(connection)

		populate_encoder_list
		@array_encoders_by_klass = array_encoders_by_klass
		@anyarray_encoder = coder_by_name(0, :encoder, '_any')
	end

	private

	def coder_by_name(format, direction, name)
		check_format_and_direction(format, direction)
		@coder_maps[format][direction].coder_by_name(name)
	end

	def populate_encoder_list
		DEFAULT_TYPE_MAP.each do |mri_type, selector|
			if Array === selector
				format, name = selector
				self[mri_type] = coder_by_name(format, :encoder, name)
			else
				self[mri_type] = selector
			end
		end
	end

	def array_encoders_by_klass
		DEFAULT_ARRAY_TYPE_MAP.inject({}) do |h, (klass, (format, name))|
			h[klass] = coder_by_name(format, :encoder, name)
			h
		end
	end

	def get_array_type(value)
		elem = value
		while elem.kind_of?(Array)
			elem = elem.first
		end
		@array_encoders_by_klass[elem.class] || @anyarray_encoder
	end

	DEFAULT_TYPE_MAP = {
		'T_TRUE'.freeze => [1, 'bool'],
		'T_FALSE'.freeze => [1, 'bool'],
		'T_FIXNUM'.freeze => [1, 'int8'],
		'T_BIGNUM'.freeze => [1, 'int8'],
		'T_FLOAT'.freeze => [0, 'float8'],
		'T_ARRAY'.freeze => :get_array_type,
	}

	DEFAULT_ARRAY_TYPE_MAP = {
		TrueClass => [0, '_bool'],
		FalseClass => [0, '_bool'],
		Fixnum => [0, '_int8'],
		Bignum => [0, '_int8'],
		String => [0, '_text'],
		Float => [0, '_float8'],
	}

end
