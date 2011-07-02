require 'thread'

class FinishJob
  def execute
    puts "shutting down #{Thread.current[:name]}"
  end
end

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
          j = get_next_or_nil
          begin
            j.execute if j
          rescue => e
            @exceptions << e
          end
        end
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
    @threads.size.times do
      add_job(FinishJob.new)
    end
  end

  def mutex
    @mutex ||= Mutex.new
  end

  def join
    @threads.each do |t|
      t.join
    end
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
  class Task

    class InvokeSupervisor
      def execution_finished(task, msg)
        puts "Supervisor: #{task.name} finished with #{msg}"
        Rake::application.thread_pool.shutdown
      end
    end

    invoke_org = self.instance_method(:invoke)
    define_method(:invoke) do |*args|
      add_execution_listener(InvokeSupervisor.new)
      Rake::application.thread_pool = ThreadPool.new(2)
      invoke_org.bind(self).call(*args)
      Rake::application.thread_pool.join
      Rake::application.thread_pool = nil
    end


    def invoke_with_call_chain(task_args, invocation_chain)
      new_chain = InvocationChain.append(self, invocation_chain)
      @lock.synchronize do
        if application.options.trace
          $stderr.puts "** Invoke #{name} #{format_trace_flags}"
        end
        return if @already_invoked
        @already_invoked = true
        invoke_prerequisites(task_args, new_chain)
      end
    rescue Exception => ex
      add_chain_to(ex, new_chain)
      raise ex
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
    class ExecuteJobWithFinish < ExecuteJob
      def initialize(task, task_args)
        super(task, task_args)
      end
      def execute
        super.execute
        puts "shutting down"
        Rake::thread_pool.shutdown
      end
    end

    def create_execute_job(task_args)
      ExecuteJob.new(self, task_args)
    end
    def add_for_execution(task_args)
      j = create_execute_job(task_args)
      Rake::application.thread_pool.add_job(j)
    end

    def invoke_prerequisites(task_args, invocation_chain) # :nodoc:
      if prerequisite_tasks.size == 0
        add_for_execution(task_args)
      else
        @task_args = task_args
        init_prereq_counts
        prerequisite_tasks.each { |prereq|
          prereq.add_execution_listener(self)
          prereq_args = task_args.new_scope(prereq.arg_names)
          prereq.invoke_with_call_chain(prereq_args, invocation_chain)
        }
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

    def execution_finished(task, msg)
      inc_prereq_count
      if msg == :ok
        inc_prereq_ok_count
      end
#      puts "i am #{name} and #{task.name} finished with #{msg}"
#      puts "prereq_count: #{prereq_count}"
#      puts "prereq_ok_count: #{prereq_ok_count}"
#      puts "prerequisites.size: #{prerequisites.size}"

      if prereq_count() == prerequisites.size
        if prereq_ok_count() == prerequisites.size
          add_for_execution(@task_args)
        else
          notify_execution_listener(:prereq_failed)
        end
      end
    end

    execute_org = self.instance_method(:execute)
    define_method(:execute) do |arg|
      begin
        execute_org.bind(self).call(arg) if needed?
        notify_execution_listener(:ok)
      rescue => e
        notify_execution_listener(:exception)
        raise e
      end
    end

    def notify_execution_listener(msg)
      execution_listener().each do |l|
        l.execution_finished(self, msg)
      end
    end

    def execution_listener
      @execution_listener ||= []
    end

    def add_execution_listener(listener)
      execution_listener() << listener
    end

    def delete_execution_listener(listener)
      execution_listener().delete(listener)
    end
  end
end

class Listener
  def execution_finished(task, msg)
    puts "task: #{task.name} finished with #{msg}"
  end
end

DELAY=2
FAILING = [2, 4].map{|i|"task#{i}"}
l = Listener.new
4.times do |i|
  t = task "task#{i+1}" do |t|
    puts  "#{t.name} sleeping"
    sleep(DELAY)
    puts  "#{t.name} ready"
    if FAILING.include?(t.name)
      raise "problem in task #{t.name}"
    end
  end
  t.add_execution_listener(l)
end

task :default => [:task1, :task2, :task3, :task4] do
  #  sh 'gibts nicht'
end
