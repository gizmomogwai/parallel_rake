$:.unshift File.join(File.dirname(__FILE__), 'lib')
$:.unshift File.join(File.dirname(__FILE__), '.')

require 'prake/task_execution_state.rb'
require 'prake/task_parallel.rb'
require 'project_setup.rb'

task :clean do
  sh 'find project -name "*.o" -delete'
  sh 'find project -name "*.exe" -delete'
  sh 'rm -f test.[c,h]'
end

task :default => [:tasks, :gen_test, 'project/main.exe']
