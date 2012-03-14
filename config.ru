#!/usr/bin/env ruby
require 'rubygems'
require 'bundler'

Bundler.require

require './imap_migrator'
require 'resque/server'

use Rack::ShowExceptions

run Rack::URLMap.new \
  "/"       => Sinatra::Application,
  "/resque" => Resque::Server.new
