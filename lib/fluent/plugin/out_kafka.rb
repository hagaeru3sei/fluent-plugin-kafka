class Fluent::KafkaOutput < Fluent::Output
  Fluent::Plugin.register_output('kafka', self)

  def initialize
    super
    require 'poseidon'
  end

  config_param :brokers, :string, :default => 'localhost:9092'
  config_param :zookeeper, :string, :default => nil
  config_param :default_topic, :string, :default => nil
  config_param :default_partition_key, :string, :default => nil
  config_param :client_id, :string, :default => 'kafka'
  config_param :output_data_type, :string, :default => 'json'
  config_param :output_include_tag, :bool, :default => false
  config_param :output_include_time, :bool, :default => false

  # poseidon producer options
  config_param :max_send_retries, :integer, :default => 3
  config_param :required_acks, :integer, :default => 0
  config_param :ack_timeout_ms, :integer, :default => 1500
  config_param :compression_codec, :string, :default => 'none'

  # extend settings
  config_param :new_keys, :string, :default => ''
  config_param :convert_values, :string, :default => ''

  attr_accessor :output_data_type
  attr_accessor :field_separator

  @seed_brokers = []

  unless method_defined?(:log)
    define_method("log") { $log }
  end

  def refresh_producer()
    if @zookeeper
      @seed_brokers = []
      z = Zookeeper.new(@zookeeper)
      z.get_children(:path => '/brokers/ids')[:children].each do |id|
        broker = Yajl.load(z.get(:path => "/brokers/ids/#{id}")[:data])
        @seed_brokers.push("#{broker['host']}:#{broker['port']}")
      end
      log.info "brokers has been refreshed via Zookeeper: #{@seed_brokers}"
    end
    begin
      if @seed_brokers.length > 0
        @producer = Poseidon::Producer.new(@seed_brokers, @client_id, :max_send_retries => @max_send_retries, :required_acks => @required_acks, :ack_timeout_ms => @ack_timeout_ms, :compression_codec => @compression_codec.to_sym)
        log.info "initialized producer #{@client_id}"
      else
        log.warn "No brokers found on Zookeeper"
      end
    rescue Exception => e
      log.error e
    end
  end

  def configure(conf)
    super
    if @zookeeper
      require 'zookeeper'
      require 'yajl'
    else
      @seed_brokers = @brokers.match(",").nil? ? [@brokers] : @brokers.split(",")
      log.info "brokers has been set directly: #{@seed_brokers}"
    end
    if @compression_codec == 'snappy'
      require 'snappy'
    end
    case @output_data_type
    when 'json'
      require 'yajl'
    when 'ltsv'
      require 'ltsv'
    when 'msgpack'
      require 'msgpack'
    end

    @f_separator = case @field_separator
                   when /SPACE/i then ' '
                   when /COMMA/i then ','
                   when /SOH/i then "\x01"
                   else "\t"
                   end

    @custom_attributes = if @output_data_type == 'json'
                           nil
                         elsif @output_data_type == 'ltsv'
                           nil
                         elsif @output_data_type == 'msgpack'
                           nil
                         elsif @output_data_type =~ /^attr:(.*)$/
                           $1.split(',').map(&:strip).reject(&:empty?)
                         else
                           @formatter = Fluent::Plugin.new_formatter(@output_data_type)
                           @formatter.configure(conf)
                           nil
                         end

    @n_keys = @new_keys.split(',').inject({}) { |n_keys, kv|
      key, default_value = kv.split(':')
      n_keys[key] = default_value; n_keys
    } if @new_keys.length > 0

  end

  def start
    super
    refresh_producer()
  end

  def shutdown
    super
  end

  def parse_record(record)
    if @custom_attributes.nil?
      case @output_data_type
      when 'json'
        Yajl::Encoder.encode(record)
      when 'ltsv'
        LTSV.dump(record)
      when 'msgpack'
        record.to_msgpack
      else
        record.to_s
      end
    else
      @custom_attributes.unshift('time') if @output_include_time
      @custom_attributes.unshift('tag') if @output_include_tag
      @custom_attributes.map { |attr|
        record[attr].nil? ? '' : record[attr].to_s
      }.join(@f_separator)
    end
  end

  def emit(tag, es, chain)
    begin
      chain.next
      es.each do |time,record|
        record['time'] = time if @output_include_time
        record['tag'] = tag if @output_include_tag
        topic = record['topic'] || self.default_topic || tag
        partition_key = record['partition_key'] || @default_partition_key

        if @new_keys.length > 0
          new_record = convert_columns(record)
        else
          new_record = record
        end

        value = @formatter.nil? ? parse_record(new_record) : @formatter.format(tag, time, new_record)
        log.trace("message send to #{topic} with key: #{partition_key} and value: #{value}.")
        message = Poseidon::MessageToSend.new(topic, value, partition_key)
        @producer.send_messages([message])
      end
    rescue Exception => e
      log.warn("Send exception occurred: #{e}")
      refresh_producer()
      raise e
    end
  end

  def convert_columns(record)
    result = record.inject({}) { |result, (key, value)|
      result[key] = convert_value(value) if @n_keys.key?(key)
      result
    }
    @n_keys.each { |key, value|
      result[key] = value unless result.key?(key)
    }
    result
  end

  def convert_value(value)
    @convert_values.split(',').each { |conv_value|
      orig, conv = conv_value.split(':')
      conv = '' if conv == '""' or conv == "''"
      return conv if value == orig
    } if @convert_values.length > 0
    value
  end

end
