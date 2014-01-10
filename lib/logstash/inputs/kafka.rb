require 'logstash/namespace'
require 'logstash/inputs/base'
require 'jruby-kafka'

class LogStash::Inputs::Kafka < LogStash::Inputs::Base
  config_name 'kafka'
  milestone 1

  default :codec, 'plain'

  config :zk_connect, :validate => :string, :required => true
  config :group_id, :validate => :string, :required => true
  config :topic_id, :validate => :string, :required => true
  config :reset_beginning, :validate => :boolean, :default => false
  config :consumer_threads, :validate => :number, :default => 1
  config :queue_size, :validate => :number, :default => 20
  config :rebalance_max_retries, :validate => :number, :default => 4
  config :rebalance_backoff_ms, :validate => :number, :default => 2000
  config :consumer_timeout_ms, :validate => :number, :default => -1
  config :consumer_restart_on_error, :validate => :boolean, :default => true
  config :consumer_restart_sleep_ms, :validate => :number, :default => 0

  public
  def register
    jarpath = File.join(File.dirname(__FILE__), "../../../vendor/jar/kafka*.jar")
    Dir[jarpath].each do |jar|
      require jar
    end
    options = {
        :zk_connect => @zk_connect,
        :group_id => @group_id,
        :topic_id => @topic_id,
        :rebalance_max_retries => @rebalance_max_retries,
        :rebalance_backoff_ms => @rebalance_backoff_ms,
        :consumer_timeout_ms => @consumer_timeout_ms,
        :consumer_restart_on_error => @consumer_restart_on_error,
        :consumer_restart_sleep_ms => @consumer_restart_sleep_ms
    }
    if @reset_beginning == true
      options[:reset_beginning] = 'from-beginning'
    end # if :reset_beginning
    @kafka_client_queue = SizedQueue.new(@queue_size)
    @consumer_group = Kafka::Group.new(options)
    @logger.info('Registering kafka', :group_id => @group_id, :topic_id => @topic_id, :zk_connect => @zk_connect)
  end # def register

  public
  def run(logstash_queue)
    java_import 'kafka.common.ConsumerRebalanceFailedException'
    @logger.info('Running kafka', :group_id => @group_id, :topic_id => @topic_id, :zk_connect => @zk_connect)
    begin
      @consumer_group.run(@consumer_threads,@kafka_client_queue)
      begin
        while true
          event = @kafka_client_queue.pop
          if event == :stop_plugin
            break
          else
            queue_event("#{event}",logstash_queue)
          end
        end
      rescue LogStash::ShutdownSignal
        @logger.info('Kafka got shutdown signal')
        @consumer_group.shutdown()
      end
      until @kafka_client_queue.empty?
        queue_event("#{@kafka_client_queue.pop}",logstash_queue)
      end
      @logger.info('Done running kafka input')
    rescue => e
      @logger.warn('kafka client threw exception, restarting',
                   :exception => e)
      if @consumer_group.running?
        @consumer_group.shutdown()
      end
      sleep(Float(@consumer_restart_sleep_ms) * 1 / 1000)
      retry
    end
    finished
  end # def run

  public
  def teardown
    @kafka_client_queue.push(:stop_plugin)
  end

  private
  def queue_event(msg, output_queue)
    begin
      @codec.decode(msg) do |event|
        decorate(event)
        event['kafka'] = {'msg_size' => msg.bytesize, 'topic' => @topic_id, 'consumer_group' => @group_id}
        output_queue << event
      end # @codec.decode
    rescue => e # parse or event creation error
      @logger.error("Failed to create event", :message => msg, :exception => e,
                    :backtrace => e.backtrace);
    end # begin
  end # def queue_event

end #class LogStash::Inputs::Kafka