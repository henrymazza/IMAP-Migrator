# encoding: utf-8

require 'resque'
require 'net/imap'
require 'pony'
require 'erb'
require './lib/cryptical'
require 'rfc2047'

module IMAPMigrator
  module Worker
    @queue = :email_migration

    # Migrates all mail from one server to another
    def self.perform(params)
      begin
      #TODO delete this
      puts params.inspect

      source_password = Cryptical.decrypt params['encrypted_source_password'], "salt"
      dest_password = Cryptical.decrypt params['encrypted_dest_password'], "salt"

      @params = params

      @report = Hash.new

      ds 'connecting...'
      source = Net::IMAP.new params['source_server'], 993, true
      ds 'logging in...'
      source.login params['source_email'], source_password

      dd 'connecting...'
      dest = Net::IMAP.new params['dest_server'], 993, true
      dd 'logging in...'
      dest.login params['dest_email'], dest_password

      sent_folders = []
      
      [source, dest].each do |mail|
        probable_sent = {}

        # colect folders that match and take theirs messages count
        mail.list('', '*').map(&:name).select{|folder| folder =~ /sent|enviad[oa]s/i}.each do |f|
          mail.examine f
          uids = mail.uid_search(['ALL'])
          probable_sent[f] = uids.length
        end
        sent_folders << probable_sent.sort_by{|k,v| v}.last[0].to_s
      end

      # populate mappings with the sent directory - this is probably the one
      # with sent in the name and the most messages in it
      mappings = {
        sent_folders[0] => sent_folders[1]
      }

      # Guarantees that none is left behind - renames folder to the GMail standard
      source.list('', '*').each do |f|
        mappings[f.name] = f.name.gsub(/^INBOX\./, '').gsub('.', '/') unless mappings[f.name]
      end

      # Loop through folders and copy messages.
      mappings.each do |source_folder, dest_folder|

        transfer = "#{source_folder} => #{dest_folder}"
        @report[transfer] = Hash.new

        puts "\nProcessing: #{source_folder} => #{dest_folder}"

        # Open source folder in read-only mode.
        begin
          ds "selecting folder '#{source_folder}'..."
          source.examine(source_folder)
        rescue => e
          ds "error: select failed: #{e}"
          next
        end

        # Open (or create) destination folder in read-write mode.
        begin
          dd "selecting folder '#{dest_folder}'..."
          dest.select(dest_folder)
        rescue => e
          begin
            dd "folder not found; creating..."
            dest.create(dest_folder)
            dest.select(dest_folder)
          rescue => ee
            dd "error: could not create folder: #{e}"
            next
          end
        end

        dd 'analyzing existing messages...'
        uids = dest.uid_search(['ALL'])

        # Build a lookup hash of all message ids present in the destination folder.
        dest_info = {}

        dd "found #{uids.length} messages"
        if uids.length > 0
          uid_fetch_block(dest, uids, ['ENVELOPE']) do |data|
            id = data.attr['ENVELOPE'].message_id
            unless id
              puts ">>>> NULL <<<<<"
            end
            if defined? dest_inf and dest_inf[id]
              puts ">>>> DUPLICATED ID <<<<<"
            end
            dest_info[id] = true
          end
          dd "Mapped #{dest_info.length} mails"
        end
        @report[transfer][:dest] = "#{uids.length}"


        # Loop through all messages in the source folder.
        uids = source.uid_search(['ALL'])
        ds "found #{uids.length} messages"

        @report[transfer][:source] = uids.length
        @report[transfer][:transfered] = 0

        if uids.length > 0
          uid_fetch_block(source, uids, ['ENVELOPE', 'RFC822.SIZE']) do |data|
            mid = data.attr['ENVELOPE'].message_id

            if data.attr['RFC822.SIZE'] > 20_000_000
              tell_admin "Message size exceeds append limit.", data.attr['ENVELOPE']
              ds "Mensagem muito grande, pulando"
              next
            end

            # If this message is already in the destination folder, skip it.
            next if dest_info[mid]

            # Download the full message body from the source folder.
            ds "downloading message #{mid}...\n#{Rfc2047.decode(data.attr['ENVELOPE'].subject)}"
            msg = source.uid_fetch(data.attr['UID'], ['RFC822', 'FLAGS', 'INTERNALDATE', 'RFC822.SIZE']).first
            ds "OK. Size: #{msg.attr['RFC822.SIZE']} - Date: #{msg.attr['INTERNALDATE']}"

            # Append the message to the destination folder, preserving flags and internal timestamp.
            dd "storing message #{mid}..."
            success = false
            begin
              dest.append(dest_folder, msg.attr['RFC822'], msg.attr['FLAGS'], msg.attr['INTERNALDATE'])
              success = true
              @report[transfer][:transfered] += 1
            rescue Net::IMAP::NoResponseError => e
              puts "Got exception: #{e.message}. Retrying..."
              tell_admin e.message, msg.attr['RFC822']
              sleep 1
            end until success
          end
        end
        uids = dest.uid_search(['ALL'])
        @report[transfer][:dest] = "#{@report[transfer][:dest]} > #{uids.length}"
        source.close
        dest.close
      end
      
      email = ERB.new(File.read('views/email.erb'))

      Pony.mail :to => params['source_email'],
            :cc => 'fabio.mazarotto@me.com',
            :from => "lamigra@officina.me",
            :subject => "Migração Completa!",
            :body => email.result(binding)

      rescue Exception => e
        tell_admin "Uncaught Exception", 
          <<-EOS 
        #{e.message}

        Stack Trace:
        #{e.backtrace.inspect}
        EOS
      end
    end

    protected
    def self.tell_admin subject, body
      Pony.mail :to => 'fabio.mazarotto@me.com',
        :from => "lamigra@officina.me",
        :subject => subject,
        :body => body
    end
    def self.ds(message)
      puts "[#{ @params['source_server'] }] #{message}"
    end

    def self.dd(message)
      puts "[#{ @params['dest_server'] }] #{message}"
    end

    # 1024 is the max number of messages to select at once
    def self.uid_fetch_block(server, uids, *args)
      pos = 0
      while pos < uids.size
        server.uid_fetch(uids[pos, 1024], *args).each { |data| yield data }
        pos += 1024
      end
    end
  end
end
