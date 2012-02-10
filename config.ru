#!/usr/bin/env ruby
require './imap_migrator'
require 'resque/server'

use Rack::ShowExceptions

run Rack::URLMap.new \
  "/"       => Sinatra::Application,
  "/resque" => Resque::Server.new
