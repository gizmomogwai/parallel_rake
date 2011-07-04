module Rake
  module TaskManager
    def define_task(task_class, *args, &block)
      task_names, arg_names, deps = resolve_args(args)
      task = task_class.new(task_names, self)
      task.set_arg_names(arg_names) unless arg_names.empty?
      add_location(task)
      task.add_description(get_description(task))
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
  end
end
