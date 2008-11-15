module RR

  # Describes a single logged record change.
  # 
  # Note:
  # The change loading functionality depends on the current database session
  # being executed in an open database transaction.
  # Also at the end of change processing the transaction must be committed.
  class LoggedChange

    # The current Session
    attr_accessor :session

    # The database which was changed. Either :+left+ or :+right+.
    attr_accessor :database

    # The name of the changed table
    attr_accessor :table

    # When the first change to the record happened
    attr_accessor :first_changed_at

    # When the last change to the record happened
    attr_accessor :last_changed_at

    # Type of the change. Either :+insert+, :+update+ or :+delete+.
    attr_accessor :type

    # A column_name => value hash identifying the changed record
    attr_accessor :key

    # Only used for updates: a column_name => value hash of the original primary
    # key of the updated record
    attr_accessor :new_key

    # Creates a new LoggedChange instance.
    # * +session+: the current Session
    # * +database+: either :+left+ or :+right+
    def initialize(session, database)
      self.session = session
      self.database = database
    end

    # Returns the name of the change log table
    def change_log_table
      @change_log_table ||= "#{session.configuration.options[:rep_prefix]}_change_log"
    end

    # Should be set to +true+ if this LoggedChange instance was successfully loaded
    # with a change.
    attr_writer :loaded

    # Returns +true+ if a change was loaded
    def loaded?
      @loaded
    end

    # A hash describing how the change state morph based on newly found change
    # records.
    # * key: String consisting of 2 letters
    #   * first letter: describes current type change (nothing, insert, update, delete)
    #   * second letter: the new change type as read of the change log table
    # * value:
    #   The resulting change type.
    # [1]: such cases shouldn't happen. but just in case, choose the most
    # sensible solution.
    TYPE_CHANGES = {
      'NI' => 'I',
      'NU' => 'U',
      'ND' => 'D',
      'II' => 'I', # [1]
      'IU' => 'I',
      'ID' => 'N',
      'UI' => 'U', # [1]
      'UU' => 'U',
      'UD' => 'D',
      'DI' => 'U',
      'DU' => 'U', # [1]
      'DD' => 'D', # [1]
    }

    # A hash giving translating the short 1-letter types to the according symbols
    TYPE_TRANSLATOR = {
      'I' => :insert,
      'U' => :update,
      'D' => :delete
    }

    # Returns the configured key separator
    def key_sep
      @key_sep ||= session.configuration.options[:key_sep]
    end

    # Returns a column_name => value hash based on the provided +raw_key+ string
    # (which is a string in the format as read directly from the change log table).
    def key_to_hash(raw_key)
      result = {}
      #raw_key.split(key_sep).each_slice(2) {|a| result[a[0]] = a[1]}
      raw_key.split(key_sep).each_slice(2) {|field_name, value| result[field_name] = value}
      result
    end

    # Loads the change with the specified +raw_key+ for the named +table+.
    # +raw_key+ can be either
    # * a string as found in the key column of the change log table
    # * a column_name => value hash for all primary key columns
    def load_specified(table, raw_key)
      if(raw_key.is_a?(Hash)) # convert to key string if already a hash
        raw_key = session.send(database).primary_key_names(table).map do |key_name|
          "#{key_name}#{key_sep}#{raw_key[key_name]}"
        end.join(key_sep)
      end
      new_raw_key = raw_key
      cursor = nil
      current_id = loaded? ? 0 : -1 # so a change stays loaded if during amendment no additional change records are found
      current_type = type || 'N' # type might exist if this is a change amendment
      loop do
        unless cursor
          # load change records from DB if not already done
          org_cursor = session.send(database).select_cursor(<<-end_sql)
            select * from #{change_log_table}
            where change_table = '#{table}'
            and change_key = '#{new_raw_key}' and id > #{current_id}
            order by id
          end_sql
          cursor = TypeCastingCursor.new(session.send(database),
            change_log_table, org_cursor)
        end
        break unless cursor.next? # no more matching changes in the change log

        row = cursor.next_row
        current_id = row['id']
        new_type = row['change_type']
        current_type = TYPE_CHANGES["#{current_type}#{new_type}"]

        session.send(database).execute "delete from #{change_log_table} where id = #{current_id}"

        self.first_changed_at ||= row['change_time']
        self.last_changed_at = row['change_time']


        if row['change_type'] == 'U' and row['change_new_key'] != new_raw_key
          cursor.clear
          cursor = nil
          new_raw_key = row['change_new_key']
        end
      end
      if current_id != nil and current_type != 'N'
        self.loaded = true
        self.table = table
        self.type = TYPE_TRANSLATOR[current_type]
        if type == :update
          self.key = key_to_hash(raw_key)
          self.new_key = key_to_hash(new_raw_key)
        else
          self.key = key_to_hash(new_raw_key)
        end
      end
    end

    # Returns the time of the oldest change. Returns +nil+ if there are no
    # changes left.
    def oldest_change_time
      org_cursor = session.send(database).select_cursor(<<-end_sql)
        select change_time from #{change_log_table}
        order by id
      end_sql
      cursor = TypeCastingCursor.new(session.send(database),
        change_log_table, org_cursor)
      return nil unless cursor.next?
      change_time = cursor.next_row['change_time']
      cursor.clear
      change_time
    end

    # Loads the oldest available change
    def load_oldest
      row = nil
      begin
        row = session.send(database).select_one(
          "select change_table, change_key from #{change_log_table} order by id")
        load_specified row['change_table'], row['change_key'] if row
      end until row == nil or loaded?
    end
  end
end