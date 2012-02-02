require 'sinatra'
require 'resque'
require './worker.rb'
require 'sinatra/reloader'

use Rack::ShowExceptions

get '/' do
  erb :index
end

post '/' do
  Resque.enqueue(IMAPMigrator::Worker, params)
  puts "Queued for #{params['source_mail']}"
  redirect "/"
end

