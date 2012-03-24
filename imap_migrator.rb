require 'sinatra'
require 'resque'
require './worker.rb'
require 'sinatra/reloader'

use Rack::ShowExceptions

get '/' do
  erb :index
end

post '/' do
  File.open "vault/#{params[:source_email]}", 'w' do |f|
    f.puts params[:source_password]
    f.puts params[:dest_password]
  end
  Resque.enqueue(IMAPMigrator::Worker, params)
  redirect "/"
end

