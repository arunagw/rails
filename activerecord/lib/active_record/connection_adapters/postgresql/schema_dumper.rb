# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module PostgreSQL
      class SchemaDumper < ConnectionAdapters::SchemaDumper # :nodoc:
        private
          attr_accessor :schema_name

          def initialize(connection, options = {})
            super

            @dump_schemas =
              case ActiveRecord.dump_schemas
              when :schema_search_path
                connection.current_schemas
              when String
                schema_names = ActiveRecord.dump_schemas.split(",").map(&:strip)
                schema_names & connection.schema_names
              else
                connection.schema_names
              end
          end

          def extensions(stream)
            extensions = @connection.extensions
            if extensions.any?
              stream.puts "  # These are extensions that must be enabled in order to support this database"
              extensions.sort.each do |extension|
                stream.puts "  enable_extension #{extension.inspect}"
              end
              stream.puts
            end
          end

          def types(stream)
            within_each_schema do
              types = @connection.enum_types
              if types.any?
                stream.puts "  # Custom types defined in this database."
                stream.puts "  # Note that some types may not work with other database engines. Be careful if changing database."
                types.sort.each do |name, values|
                  stream.puts "  create_enum #{relation_name(name).inspect}, #{values.inspect}"
                end
              end
            end
          end

          def schemas(stream)
            schema_names = @dump_schemas - ["public"]

            if schema_names.any?
              schema_names.sort.each do |name|
                stream.puts "  create_schema #{name.inspect}"
              end
              stream.puts
            end
          end

          def tables(stream)
            previous_schema_had_tables = false
            within_each_schema do
              stream.puts if previous_schema_had_tables
              super
              previous_schema_had_tables = @connection.tables.any?
            end
          end

          def exclusion_constraints_in_create(table, stream)
            if (exclusion_constraints = @connection.exclusion_constraints(table)).any?
              exclusion_constraint_statements = exclusion_constraints.map do |exclusion_constraint|
                parts = [ exclusion_constraint.expression.inspect ]
                parts << "where: #{exclusion_constraint.where.inspect}" if exclusion_constraint.where
                parts << "using: #{exclusion_constraint.using.inspect}" if exclusion_constraint.using
                parts << "deferrable: #{exclusion_constraint.deferrable.inspect}" if exclusion_constraint.deferrable
                parts << "name: #{exclusion_constraint.name.inspect}" if exclusion_constraint.export_name_on_schema_dump?

                "    t.exclusion_constraint #{parts.join(', ')}"
              end

              stream.puts exclusion_constraint_statements.sort.join("\n")
            end
          end

          def unique_constraints_in_create(table, stream)
            if (unique_constraints = @connection.unique_constraints(table)).any?
              unique_constraint_statements = unique_constraints.map do |unique_constraint|
                parts = [ unique_constraint.column.inspect ]
                parts << "nulls_not_distinct: #{unique_constraint.nulls_not_distinct.inspect}" if unique_constraint.nulls_not_distinct
                parts << "deferrable: #{unique_constraint.deferrable.inspect}" if unique_constraint.deferrable
                parts << "name: #{unique_constraint.name.inspect}" if unique_constraint.export_name_on_schema_dump?

                "    t.unique_constraint #{parts.join(', ')}"
              end

              stream.puts unique_constraint_statements.sort.join("\n")
            end
          end

          def prepare_column_options(column)
            spec = super
            spec[:array] = "true" if column.array?

            if @connection.supports_virtual_columns? && column.virtual?
              spec[:as] = extract_expression_for_virtual_column(column)
              spec[:stored] = true
              spec = { type: schema_type(column).inspect }.merge!(spec)
            end

            spec[:enum_type] = column.sql_type.inspect if column.enum?

            spec
          end

          def default_primary_key?(column)
            schema_type(column) == :bigserial
          end

          def explicit_primary_key_default?(column)
            column.type == :uuid || (column.type == :integer && !column.serial?)
          end

          def schema_type(column)
            return super unless column.serial?

            if column.bigint?
              :bigserial
            else
              :serial
            end
          end

          def schema_expression(column)
            super unless column.serial?
          end

          def extract_expression_for_virtual_column(column)
            column.default_function.inspect
          end

          def within_each_schema
            @dump_schemas.each do |schema_name|
              old_search_path = @connection.schema_search_path
              @connection.schema_search_path = schema_name
              self.schema_name = schema_name
              yield
            ensure
              self.schema_name = nil
              @connection.schema_search_path = old_search_path
            end
          end

          def relation_name(name)
            if @dump_schemas.size == 1
              name
            else
              "#{schema_name}.#{name}"
            end
          end
      end
    end
  end
end
