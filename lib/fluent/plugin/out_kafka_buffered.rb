# encode: utf-8
class Fluent::KafkaOutputBuffered < Fluent::BufferedOutput
  Fluent::Plugin.register_output('kafka_buffered', self)

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
  config_param :kafka_agg_max_bytes, :size, :default => 4*1024  #4k

  # poseidon producer options
  config_param :max_send_retries, :integer, :default => 3
  config_param :required_acks, :integer, :default => 0
  config_param :ack_timeout_ms, :integer, :default => 1500
  config_param :compression_codec, :string, :default => 'none'

  # extend settings
  config_param :new_keys, :string, :default => nil
  config_param :convert_values, :string, :default => nil

  attr_accessor :output_data_type
  attr_accessor :field_separator

  unless method_defined?(:log)
    define_method("log") { $log }
  end

  @seed_brokers = []

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

    @f_separator = case @field_separator
                   when /SPACE/i then ' '
                   when /COMMA/i then ','
                   when /SOH/i then "\x01"
                   else "\t"
                   end

    @formatter_proc = setup_formatter(conf)

    @n_keys = @new_keys.split(',').inject({}) { |n_keys, kv|
      key, default_value = kv.split(':')
      n_keys[key] = default_value; n_keys
    }
  end

  def start
    super
    refresh_producer()
  end

  def shutdown
    super
  end

  def format(tag, time, record)
    [tag, time, record].to_msgpack
  end

  def setup_formatter(conf)
    if @output_data_type == 'json'
      require 'yajl'
      Proc.new { |tag, time, record| Yajl::Encoder.encode(record) }
    elsif @output_data_type == 'ltsv'
      require 'ltsv'
      Proc.new { |tag, time, record| LTSV.dump(record) }
    elsif @output_data_type == 'msgpack'
      require 'msgpack'
      Proc.new { |tag, time, record| record.to_msgpack }
    elsif @output_data_type =~ /^attr:(.*)$/
      @custom_attributes = $1.split(',').map(&:strip).reject(&:empty?)
      @custom_attributes.unshift('time') if @output_include_time
      @custom_attributes.unshift('tag') if @output_include_tag
      Proc.new { |tag, time, record|
        @custom_attributes.map { |attr|
          record[attr].nil? ? '' : record[attr].to_s
        }.join(@f_separator)
      }
    else
      @formatter = Fluent::Plugin.new_formatter(@output_data_type)
      @formatter.configure(conf)
      Proc.new { |tag, time, record|
        @formatter.format(tag, time, record)
      }
    end
  end

  def write(chunk)
    records_by_topic = {}
    bytes_by_topic = {}
    messages = []
    messages_bytes = 0
    begin
      chunk.msgpack_each { |tag, time, record|
        record['time'] = time if @output_include_time
        record['tag'] = tag if @output_include_tag
        topic = record['topic'] || @default_topic || tag
        partition_key = record['partition_key'] || @default_partition_key

        if @new_keys.length > 0
          new_record = convert_columns(record)
        else
          new_record = record
        end

        records_by_topic[topic] ||= 0
        bytes_by_topic[topic] ||= 0

        record_buf = @formatter_proc.call(tag, time, new_record)
        record_buf_bytes = record_buf.bytesize
        if messages.length > 0 and messages_bytes + record_buf_bytes > @kafka_agg_max_bytes
          log.on_trace { log.trace("#{messages.length} messages send.") }
          @producer.send_messages(messages)
          messages = []
          messages_bytes = 0
        end
        log.on_trace { log.trace("message will send to #{topic} with key: #{partition_key} and value: #{record_buf}.") }
        messages << Poseidon::MessageToSend.new(topic, record_buf, partition_key)
        messages_bytes += record_buf_bytes

        records_by_topic[topic] += 1
        bytes_by_topic[topic] += record_buf_bytes
      }
      if messages.length > 0
        log.trace("#{messages.length} messages send.")
        @producer.send_messages(messages)
      end
      log.debug "(records|bytes) (#{records_by_topic}|#{bytes_by_topic})"
    end
  rescue Exception => e
    log.warn "Send exception occurred: #{e}"
    refresh_producer()
    # Raise exception to retry sendind messages
    raise e
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
