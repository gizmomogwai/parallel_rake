require 'rake'
require 'prake/task_execution_state.rb'

# TODO ... notify wait auf der jobqueue
#class FinishJob
#  def execute
#    puts "shutting down #{Thread.current[:name]}"
#  end
#end

class ThreadPool
  def initialize(nr_of_threads)
    @jobs = []
    @running = true
    @threads = []
    @exceptions = []
    nr_of_threads.times do |i|
      @threads << Thread.new(i) do
        Thread.current[:name] = "ThreadPoolThread#{i}"
        while (@running)
          sleep(1)
          puts "still running #{i}"
          j = get_next_or_nil
          begin
            j.execute if j
          rescue => e
            @exceptions << e
          end
        end
        puts "leaving thread #{i}"
      end
    end
  end

  def get_next_or_nil
    mutex.synchronize do
      @jobs.shift
    end
  end

  def add_job(j)
    mutex.synchronize do
      @jobs << j
    end
  end

  def shutdown
    @running = false
#    @threads.size.times do
#      add_job(FinishJob.new)
#    end
#    @running = false
  end

  def mutex
    @mutex ||= Mutex.new
  end

  def join
    @threads.each do |t|
      t.join
    end
    puts @jobs.join(', ')
    if @exceptions.size > 0
      puts "problems:"
      puts @exceptions.join("\n")
    end
  end
end

module Rake
  class Application
    def thread_pool=(t)
      @thread_pool = t
    end
    def thread_pool
      @thread_pool
    end
  end

  class InvokeSupervisor
    def name
      'InvokeSupervisor'
    end
    def execution_state_changed(task, state)
      if state.execution_finished?
        Rake::application.thread_pool.shutdown
      end
    end
  end

  class Task

    invoke_org = self.instance_method(:invoke)
    define_method(:invoke) do |*args|
      add_execution_state_listener(InvokeSupervisor.new)
      Rake::application.thread_pool = ThreadPool.new(4)
      invoke_org.bind(self).call(*args)
      Rake::application.thread_pool.join
      Rake::application.thread_pool = nil
    end

    def invoke_with_call_chain(task_args, invocation_chain)
      new_chain = InvocationChain.append(self, invocation_chain)
#      @lock.synchronize do
        if application.options.trace
          $stderr.puts "** Invoke #{name} #{format_trace_flags}"
        end
        invoke_prerequisites_and_execute(task_args, new_chain)
 #     end
      #    rescue Exception => ex
      #      add_chain_to(ex, new_chain)
      #      raise ex
    end

    def invoke_prerequisites_and_execute(task_args, invocation_chain)
      execution_state_mutex.synchronize do
        if execution_state.idle?
          self.execution_state = ExecutionState.invoked
          if prerequisites.size == 0
            add_for_execution(task_args)
          else
            @task_args = task_args
            init_prereq_counts
            prerequisites.each { |name|
              prereq = Rake.application[name]
              prereq.execution_state_mutex.synchronize do
                prereq_state = prereq.execution_state
                if prereq_state.execution_finished?
                  execution_state_changed(prereq, prereq_state)
                else
                  prereq.add_execution_state_listener(self)
                  prereq_args = task_args.new_scope(prereq.arg_names)
                  prereq.invoke_with_call_chain(prereq_args, invocation_chain)
                end
              end
            }
          end
        end
        # if not idle do nothing
      end
    end


    def init_prereq_counts
      @prereq_count = 0
      @prereq_ok_count = 0
      @prereq_mutex = Mutex.new
    end

    attr_reader :prereq_count, :prereq_ok_count

    def inc_prereq_count
      @prereq_mutex.synchronize do
        @prereq_count += 1
      end
    end

    def inc_prereq_ok_count
      @prereq_mutex.synchronize do
        @prereq_ok_count += 1
      end
    end

    def execution_state_changed(task, state)
      if !state.execution_finished?
        return
      end

      inc_prereq_count
      if state.ok?
        inc_prereq_ok_count
      end
#      puts "i am #{name} and #{task.name} finished with #{state}\nprereq_count: #{prereq_count}\nprereq_ok_count: #{prereq_ok_count}\nprerequisites.size: #{prerequisites.size} - #{prerequisites.join(', ')}"

      if prereqs_finished?
        if prereqs_ok?
          add_for_execution(@task_args)
        else
          execution_state_mutex.synchronize do
            self.execution_state = ExecutionState.failed_because_of_prereq
          end
        end
      end
    end

    def prereqs_finished?
      prereq_count() == prerequisites.size
    end

    def prereqs_ok?
      prereq_ok_count() == prerequisites.size
    end


    class ExecuteJob
      def initialize(task, task_args)
        @task = task
        @task_args = task_args
      end
      def execute
        @task.execute(@task_args)
      end
    end

    def add_for_execution(task_args)
      execution_state_mutex.synchronize do
        if needed?
          self.execution_state = ExecutionState.enqueued
          j = ExecuteJob.new(self, task_args)
          Rake::application.thread_pool.add_job(j)
        else
          self.execution_state = ExecutionState.not_needed
        end
      end
    end


    execute_org = self.instance_method(:execute)
    define_method(:execute) do |arg|
      begin
        execute_org.bind(self).call(arg) if needed?
        self.execution_state = ExecutionState.ok
      rescue => e
        self.execution_state = ExecutionState.failed(e)
        raise e
      end
    end


  end
end
