require 'sinatra'
require 'resque'
require './worker.rb'
require 'sinatra/reloader'
require './lib/cryptical'

use Rack::ShowExceptions

get '/' do
  erb :index
end

post '/' do

  params[:encrypted_source_password] = Cryptical.encrypt params[:source_password], "salt"
  params[:encrypted_dest_password] = Cryptical.encrypt params[:dest_password], "salt"

  Resque.enqueue(IMAPMigrator::Worker, params)
  redirect "/"
end

