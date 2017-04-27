module Fluent
  class ConcatFilter < Filter
    Plugin.register_filter("k8s_concat", self)

    desc "The key for part of multiline log"
    config_param :key, :string, required: true
    desc "The separator of lines"
    config_param :separator, :string, default: "\n"
    desc "The number of lines"
    config_param :n_lines, :integer, default: nil
    desc "The regexp to match beginning of multiline"
    config_param :multiline_start_regexp, :string, default: nil
    desc "The regexp to match ending of multiline"
    config_param :multiline_end_regexp, :string, default: nil
    desc "The key to determine which stream an event belongs to"
    config_param :stream_identity_key, :string, default: nil
    desc "The interval between data flushes, 0 means disable timeout"
    config_param :flush_interval, :time, default: 60
    desc "The label name to handle timeout"
    config_param :timeout_label, :string, default: nil
    desc "Use timestamp of first record when buffer is flushed"
    config_param :use_first_timestamp, :bool, default: false
    desc "The record key that overrides multiline_start_regexp"
    config_param :regexp_override_key, :string, default: "kubernetes_annotations_multiline_log"

    class TimeoutError < StandardError
    end

    def initialize
      super

      @buffer = Hash.new {|h, k| h[k] = [] }
      @timeout_map = Hash.new {|h, k| h[k] = Fluent::Engine.now }
    end

    def configure(conf)
      super

      if @n_lines && @multiline_start_regexp
        raise ConfigError, "n_lines and multiline_start_regexp are exclusive"
      end
      if @n_lines.nil? && @multiline_start_regexp.nil?
        raise ConfigError, "Either n_lines or multiline_start_regexp is required"
      end

      @mode = nil
      case
      when @n_lines
        @mode = :line
      when @multiline_start_regexp
        @mode = :regexp
        @multiline_start_regexp = Regexp.compile(@multiline_start_regexp[1..-2])
        if @multiline_end_regexp
          @multiline_end_regexp = Regexp.compile(@multiline_end_regexp[1..-2])
        end
      end
    end

    def start
      super
      @finished = false
      @loop = Coolio::Loop.new
      timer = TimeoutTimer.new(1, method(:on_timer))
      @loop.attach(timer)
      @thread = Thread.new(@loop, &:run)
    end

    def shutdown
      super
      @finished = true
      @loop.watchers.each(&:detach)
      @loop.stop
      @thread.join
      flush_remaining_buffer
    end

    def filter_stream(tag, es)
      new_es = MultiEventStream.new
      es.each do |time, record|
        begin
          flushed_es = process(tag, time, record)
          unless flushed_es.empty?
            flushed_es.each do |_time, new_record|
              time = _time if @use_first_timestamp
              new_es.add(time, record.merge(new_record))
            end
          end
        rescue => e
          router.emit_error_event(tag, time, record, e)
        end
      end
      new_es
    end

    private

    def on_timer
      return if @flush_interval <= 0
      return if @finished
      flush_timeout_buffer
    end

    def process(tag, time, record)
      new_es = MultiEventStream.new
      if @stream_identity_key
        stream_identity = "#{tag}:#{record[@stream_identity_key]}"
      else
        stream_identity = "#{tag}:default"
      end
      @timeout_map[stream_identity] = Fluent::Engine.now
      case @mode
      when :line
        @buffer[stream_identity] << [tag, time, record]
        if @buffer[stream_identity].size >= @n_lines
          new_time, new_record = flush_buffer(stream_identity)
          time = new_time if @use_first_timestamp
          new_es.add(time, new_record)
          return new_es
        end
      when :regexp
        case
        when firstline?(record, @key)
          if @buffer[stream_identity].empty?
            @buffer[stream_identity] << [tag, time, record]
            if lastline?(record[@key])
              new_time, new_record = flush_buffer(stream_identity)
              time = new_time if @use_first_timestamp
              new_es.add(time, new_record)
            end
          else
            new_time, new_record = flush_buffer(stream_identity, [tag, time, record])
            time = new_time if @use_first_timestamp
            new_es.add(time, new_record)
            if lastline?(record[@key])
              new_time, new_record = flush_buffer(stream_identity)
              time = new_time if @use_first_timestamp
              new_es.add(time, new_record)
            end
            return new_es
          end
        when lastline?(record[@key])
          @buffer[stream_identity] << [tag, time, record]
          new_time, new_record = flush_buffer(stream_identity)
          time = new_time if @use_first_timestamp
          new_es.add(time, new_record)
          return new_es
        else
          if @buffer[stream_identity].empty?
            new_es.add(time, record)
            return new_es
          else
            # Continuation of the previous line
            @buffer[stream_identity] << [tag, time, record]
          end
        end
      end
      new_es
    end

    def firstline?(record, key)
      start_regexp = @multiline_start_regexp
      if record.has_key? @regexp_override_key and record[@regexp_override_key].match(/^\/.+\/$/)
        start_regexp = Regexp.compile(record[@regexp_override_key][1..-2])
      end
      start_regexp && !!start_regexp.match(record[key])
    end

    def lastline?(text)
      @multiline_end_regexp && !!@multiline_end_regexp.match(text)
    end

    def flush_buffer(stream_identity, new_element = nil)
      lines = @buffer[stream_identity].map {|_tag, _time, record| record[@key] }
      _tag, time, first_record = @buffer[stream_identity].first
      new_record = {
        @key => lines.join(@separator)
      }
      @buffer[stream_identity] = []
      @buffer[stream_identity] << new_element if new_element
      [time, first_record.merge(new_record)]
    end

    def flush_timeout_buffer
      now = Fluent::Engine.now
      timeout_stream_identities = []
      @timeout_map.each do |stream_identity, previous_timestamp|
        next if @flush_interval > (now - previous_timestamp)
        next if @buffer[stream_identity].empty?
        time, flushed_record = flush_buffer(stream_identity)
        timeout_stream_identities << stream_identity
        tag = stream_identity.split(":").first
        message = "Timeout flush: #{stream_identity}"
        handle_timeout_error(tag, @use_first_timestamp ? time : now, flushed_record, message)
        log.info(message)
      end
      @timeout_map.reject! do |stream_identity, _|
        timeout_stream_identities.include?(stream_identity)
      end
    end

    def flush_remaining_buffer
      @buffer.each do |stream_identity, elements|
        next if elements.empty?

        lines = elements.map {|_tag, _time, record| record[@key] }
        new_record = {
          @key => lines.join(@separator)
        }
        tag, time, record = elements.first
        message = "Flush remaining buffer: #{stream_identity}"
        handle_timeout_error(tag, time, record.merge(new_record), message)
        log.info(message)
      end
      @buffer.clear
    end

    def handle_timeout_error(tag, time, record, message)
      if @timeout_label
        label = Engine.root_agent.find_label(@timeout_label)
        label.event_router.emit(tag, time, record)
      else
        router.emit_error_event(tag, time, record, TimeoutError.new(message))
      end
    end

    class TimeoutTimer < Coolio::TimerWatcher
      def initialize(interval, callback)
        super(interval, true)
        @callback = callback
      end

      def on_timer
        @callback.call
      end
    end
  end
end
