require 'thread'
require 'concurrent'

require 'spf/common/utils'
require 'spf/common/logger'


module SPF
  module Gateway
    class ProcessingData

    include Enumerable
    include SPF::Logging
    include SPF::Common::Utils

      def initialize(service_manager, benchmark, min_thread_size=2,
                      max_thread_size=2, max_queue_thread_size=0, queue_size=50)
        @service_manager = service_manager
        if benchmark.nil?
          @save_bench = false
        else
          @benchmark = benchmark
          @save_bench = true
        end
        @queue_size = queue_size
        @queue = Array.new # TODO: To change in a SizedQueue
        @semaphore = Mutex.new
        @pool = Concurrent::ThreadPoolExecutor.new(
          min_threads: min_thread_size,
          max_threads: max_thread_size,
          max_queue: max_queue_thread_size # unbounded work queue
        ) # that works just like a FixedThreadPool.new 2

        # last_benchmark_saved = 0
      end

      def run
        loop do
          raw_data, cam_id, gps, queue_time = pop
          if raw_data.nil? or cam_id.nil? or gps.nil?
            sleep(0.1)
          else
            @service_manager.with_pipelines_interested_in(raw_data) do |pl|
              @pool.post do
                begin
                  bench = pl.process(raw_data, cam_id, gps)
                  if @save_bench
                    unless bench.nil? or bench.empty?
                      @benchmark << [bench, (queue_time[:stop] - queue_time[:start]).to_s,
                                      queue_time[:shift].to_s].flatten

                      # if @benchmark.length % 25
                      #   CSV.open("/tmp/pipeline.processing.time-#{Time.now}", "a",
                      #             :write_headers => true,
                      #             :headers => ["Pipeline ID", "Processing CPU time",
                      #                           "Processing time", "Filtering threshold",
                      #                           "Raw byte size", "Processed", "IO byte size",
                      #                           "Queue time"]) do |csv|
                      #     @benchmark.each { |res| csv << res }
                      #     @last_benchmark_saved += 25
                      #   end
                      # end
                    end
                  end
                rescue => e
                  puts e.message
                  puts e.backtrace
                  # raise e
                end
              end
            end
          end
        end
      end

      def each(&blk)
        @semaphore.synchronize { @queue.each(&blk) }
      end

      def pop
        raw_data, cam_id, gps, queue_time = nil, nil, nil, nil
        @semaphore.synchronize do
          raw_data, cam_id, gps, queue_time = @queue.shift
          unless queue_time.nil?
            queue_time[:stop] = cpu_time if queue_time[:stop].nil?
          end
        end
        return raw_data, cam_id, gps, queue_time
      end

      def push(raw_data, cam_id, gps)
        @semaphore.synchronize do
          queue_time = Hash.new
          queue_time[:start] = cpu_time
          queue_time[:stop] = nil
          queue_time[:shift] = false
          if @queue.length >= @queue_size
            tmp_raw_data, _, _, tmp_queue_time = @queue.shift
            tmp_queue_time[:stop] = cpu_time
            tmp_queue_time[:shift] = true
            if @save_bench
              @benchmark << ["", "", "", "", tmp_raw_data.size.to_s, "false", "",
                            (tmp_queue_time[:stop] - tmp_queue_time[:start]).to_s,
                            tmp_queue_time[:shift].to_s].flatten
            end
            logger.warn "*** #{self.class.name}: Removed data from queue ***"
          end
          @queue.push([raw_data, cam_id, gps, queue_time])
        end
      end

      def to_a
        @semaphore.synchronize { @queue.to_a }
      end

      def <<(raw_data, cam_id, gps)
        push(raw_data, cam_id, gps)
      end

    end
  end
end
