require 'rake'

module Rake

  class ExecutionState
    def initialize(idle, execution_finished, ok, e=nil)
      @idle = idle
      @execution_finished = execution_finished
      @ok = ok
      @e = e
    end
    def self.idle
      ExecutionState.new(true, false, false)
    end
    def self.not_needed
      ExecutionState.new(false, true, true)
    end
    def self.ok
      ExecutionState.new(false, true, true)
    end
    def self.failed(e)
      ExecutionState.new(false, true, false, e)
    end

    def self.failed_because_of_prereq
      ExecutionState.new(false, true, false)
    end
    def self.enqueued
      ExecutionState.new(false, false, false)
    end
    def self.invoked
      ExecutionState.new(false, false, false)
    end
    def idle?
      @idle
    end

    def ok?
      return @ok
    end

    def execution_finished?
      return @execution_finished
    end
    def exception?
      @e
    end
    def to_s
      details = [:idle?, :ok?, :execution_finished?, :exception?].map{|s|self.send(s).to_s}.join(', ')
      return "ExecutionState [#{details}]"
    end

    def <=>(other)
      return to_s <=> other.to_s
    end

  end

  class Task
    def execution_state_mutex
      @execution_state_mutex ||= Monitor.new
    end

    def execution_state
      @execution_state ||= ExecutionState.idle
    end

    def execution_state=(s)
      @execution_state = s
      notify_execution_state_listener
    end

    def execution_state_listener
      @execution_state_listener ||= []
    end

    def add_execution_state_listener(l)
      listener = execution_state_listener()
      listener << l
    end

    def remote_execution_state_listener(l)
      execution_state_listener().delete(l)
    end

    def notify_execution_state_listener
      execution_state_listener().each do |l|
        l.execution_state_changed(self, execution_state)
      end
    end

  end
end

