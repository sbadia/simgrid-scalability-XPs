# Author:: Sebastien Badia (<seb@sebian.fr>)
# Date:: Fri Jun 01 14:06:12 +0200 2012

=begin

sg-scalability a engine for g5k-campaign, in order to launch SimGrid
scalability tests on Grid'5000.
For more information see <http://github.com/mquinson/simgrid-scalability-XPs/>
Copyright © 2012  Sebastien Badia

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

=end

require 'pp'
require 'yaml'
require 'optparse'

$tlaunch = Time::now
CFG = File.join(File.expand_path(File.dirname(__FILE__)),"scalab.yaml")

def time_elapsed
  return (Time::now - $tlaunch).to_i
end # def:: time_elapsed

#set a specific path for simgrid compil, so dyn replace in expe yml
def replace_yaml_tokens(yaml_doc, sgpath)
  yaml_obj = YAML::dump( yaml_doc )
  yaml_obj.gsub!(/\@SGPATH\@/, sgpath)
  YAML::load( yaml_obj )
end

class SimgridScalability < Grid5000::Campaign::Engine
  set :environment, "squeeze-x64-nfs"
  set :resources, "nodes=1"
  set :properties, "cluster='graphene'"
  set :walltime, 36000
  set :notifications, ["xmpp:#{ENV['USER']}@jabber.grid5000.fr"]
  set :site, "nancy"
  set :name, "SG::Scalab"
  #set :no_cleanup, true
  #set :no_cancel, true

  after :deployment! do |env, *args|
    logger.info "[#{env[:site]}](#{time_elapsed}) Nodes have been deployed: #{env[:nodes].inspect}"
    env
  end

  before :install! do |env, *args|
    logger.info "[#{env[:site]}](#{time_elapsed}) Installing additional software on the nodes..."
    env[:nodes].each do |node|
      ssh(node, "root",:timeout => 10) do |ssh|
        out = ssh.exec!("apt-get update && apt-get -y install debconf-utils && echo 'sun-java6-bin   shared/accepted-sun-dlj-v1-1    boolean true' | debconf-set-selections && apt-get -y install cmake-curses-gui libpcre3-dev sun-java6-jdk dtach git-core jed dc cpufrequtils")
        logger.debug out
      end
    end
    env
  end

  on :install! do |env, *args|
    Dir.chdir("/home/#{ENV['USER']}") do
      if File.directory?('simgrid')
        Dir.chdir('simgrid') do
          puts "update"
          %x{https_proxy='http://proxy:3128' git pull}
        end
      else
        puts "clone"
        %x{https_proxy='http://proxy:3128' git clone #{YAML.load_file(CFG)['sources']}}
      end
    end

    #TODO on suppose que last est deja compile
    Dir.chdir("/home/#{ENV['USER']}/simgrid") do
      LAST = %x{git log --pretty=format:%h -1}
      logger.info "[#{env[:site]}](#{time_elapsed}) Use simgrid rev #{LAST}..."
      if !File.directory?("/home/#{ENV['USER']}/sg-#{LAST}")
        Dir.mkdir("/home/#{ENV['USER']}/sg-#{LAST}")
        logger.info "[#{env[:site]}](#{time_elapsed}) Compil sg-#{LAST} on node #{env[:nodes].inspect}..."
        env[:nodes].each do |node|
          ssh(node, ENV['USER'],:timeout => 10) do |ssh|
             out = ssh.exec!("cd ~/simgrid/;cmake -DCMAKE_INSTALL_PREFIX=~/sg-#{LAST} #{YAML.load_file(CFG)['sg_opts']} ./;make;make install")
             logger.debug out
          end
        end
        #FIXME uggly
        %x{cd #{File.join(File.expand_path(File.dirname(__FILE__)),'..','simgrid-masterslave')};sed -e "s/@SG_PATH@/\\/home\\/#{ENV['USER']}\\/sg-#{LAST}\\//" -i Makefile;make}
        logger.info "[#{env[:site]}](#{time_elapsed}) Compil OK on node #{env[:nodes].inspect}..."
      end
    end
    env
  end

  on :execute! do |env, *args|
    conf = replace_yaml_tokens(YAML.load_file(CFG),"~/sg-#{LAST}")
    if conf.has_key?('sg_xp')
      conf['sg_xp'].each_pair do |xp,cmd|
        if cmd != nil
          logger.info "[#{env[:site]}](#{time_elapsed}) Launch #{xp} experiment #{LAST}..."
          ssh(env[:nodes], ENV['USER'], :multi => true, :timeout => 10) do |ssh|
            logger.info "[#{env[:site]}] Executing command: #{cmd}"
            ssh.exec(cmd)
            ssh.loop
          end # ssh loop
        end
      end # each_pair
    end # if has_key
    env
  end # on execute
end # class SimgridScalability < Grid5000::Campaign::Engine
