require 'rake'
require 'prake/task_execution_state.rb'

Thread.abort_on_exception = true

class ThreadPool
  def initialize(nr_of_threads)
    @jobs = []
    @jobs.extend(MonitorMixin)
    @jobs_cond = @jobs.new_cond

    @threads = []
    @exceptions = []
    @exceptions.extend(MonitorMixin)
    nr_of_threads.times do |i|
      @threads << Thread.new(i) do
        Thread.current[:name] = "ThreadPoolThread#{i}"
        while (true)
          j = get_next
          begin
            if j == :shutdown
              break
            else
              j.execute
            end
          rescue => e
            # puts "cought exception #{e}"
            exception_happened(e)
          end
        end
        # puts "leaving thread #{i}"
      end
    end
  end

  def exception_happened(e)
    @exceptions.synchronize do
      @exceptions << e
    end
  end

  def get_next
    @jobs.synchronize do
      res = @jobs.shift
      while !res
        @jobs_cond.wait
        res = @jobs.shift
      end
      return res
    end
  end

  def add_job(j)
    @jobs.synchronize do
      @jobs << j
      @jobs_cond.signal
    end
  end

  def shutdown
    # puts 'sending shutdown'
    @threads.size.times do
      add_job(:shutdown)
    end
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
  module TaskManager

    def define_task(task_class, *args, &block)
      task_names, arg_names, deps = resolve_args(args)
      task = task_class.new(task_names, self)
      task.set_arg_names(arg_names) unless arg_names.empty?
      deps = [deps] unless deps.respond_to?(:to_ary)
      deps = deps.collect {|d| d.to_s }
      task.enhance(deps, &block)
      task_names.each do |task_name|
        task_name = task_class.scope_name(@scope, task_name)
        register(task, task_name)
      end
      task
    end

    def register(task, task_name)
      h = @tasks[task_name.to_s]
      if h != nil
        raise "Task #{task_name} already exists"
      end
      @tasks[task_name.to_s] = task
    end

    def resolve_args(args)
      if args.last.is_a?(Hash)
        deps = args.pop
        resolve_args_with_dependencies(args, deps)
      else
        resolve_args_without_dependencies(args)
      end
    end

    def handle_task_names(args)
      first = args.shift
      if first.is_a?(Array)
        task_names = first
      else
        task_names = [first]
      end
      task_names
    end

    def resolve_args_without_dependencies(args)
      task_names = handle_task_names(args)
      if args.size == 1 && args.first.respond_to?(:to_ary)
        arg_names = args.first.to_ary
      else
        arg_names = args
      end
      [task_names, arg_names, []]
    end

    def resolve_args_with_dependencies(args, hash) # :nodoc:
      fail "Task Argument Error" if hash.size != 1
      key, value = hash.map { |k, v| [k,v] }.first
      if args.empty?
        task_names = [key]
        arg_names = []
        deps = value
      elsif key == :needs
        Rake.application.deprecate(
          "task :t, arg, :needs => [deps]",
          "task :t, [args] => [deps]",
          caller.detect { |c| c !~ /\blib\/rake\b/ })
        task_name = args.shift
        arg_names = args
        deps = value
      else
        task_names = handle_task_names(args)
        arg_names = key
        deps = value
      end
      deps = [deps] unless deps.respond_to?(:to_ary)
      [task_names, arg_names, deps]
    end
    private :resolve_args_with_dependencies
  end

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

    def initialize(task_names, app)
      @names = task_names.map{|name|name.to_s}
      @name = @names.first
      @prerequisites = []
      @actions = []
      @already_invoked = false
      @full_comment = nil
      @comment = nil
      @lock = Monitor.new
      @application = app
      @scope = app.current_scope
      @arg_names = nil
      @locations = []
    end
    attr_reader :names

    invoke_org = self.instance_method(:invoke)
    define_method(:invoke) do |*args|
      execution_state_mutex.synchronize do
        add_execution_state_listener(InvokeSupervisor.new)
      end
      Rake::application.thread_pool = ThreadPool.new(4)
      invoke_org.bind(self).call(*args)
      Rake::application.thread_pool.join
      Rake::application.thread_pool = nil
    end

    def invoke_with_call_chain(task_args, invocation_chain)
      new_chain = InvocationChain.append(self, invocation_chain)
      if application.options.trace
        $stderr.puts "** Invoke #{name} #{format_trace_flags}"
      end
      invoke_prerequisites_and_execute(task_args, new_chain)
    rescue Exception => ex
      add_chain_to(ex, new_chain)
      raise ex
    end

    def invoke_prerequisites_and_execute(task_args, invocation_chain)
      execution_state_mutex.synchronize do
        if execution_state.idle?
          self.execution_state = ExecutionState.invoked
        else
          return
        end
      end

      if prerequisites.size == 0
        add_for_execution(task_args)
      else
        @task_args = task_args
        init_prereq_counts
        prerequisites.each do |name|
          prereq = Rake::Task[name]
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
        end
      end
    end

    attr_reader :prereq_count, :prereq_ok_count
    def init_prereq_counts
      @prereq_count = 0
      @prereq_ok_count = 0
      @prereq_mutex = Mutex.new
    end

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

    # is called when the execution state of prerequisites changes
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
          Rake::application.thread_pool.add_job(ExecuteJob.new(self, task_args))
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
