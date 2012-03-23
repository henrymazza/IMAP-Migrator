# encoding: utf-8

require 'resque'
require 'net/imap'
require 'pony'

module IMAPMigrator
  module Worker
    @queue = :email_migration

    # Migrates all mail from one server to another
    def self.perform(params)
			@params = params

      @report = Hash.new

      ds 'connecting...'
      source = Net::IMAP.new params['source_server'], 993, true
      ds 'logging in...'
      source.login params['source_email'], params['source_password']

      dd 'connecting...'
      dest = Net::IMAP.new params['dest_server'], 993, true
      dd 'logging in...'
      dest.login params['dest_email'], params['dest_password']

      #TODO it would be better to be user configurable or based on server specific profiles
			if params['dest_server'] == "imap.gmail.com"
        mappings = {
          "INBOX"               => "Inbox",
          "INBOX.Sent Messages" => '[Gmail]/Sent Mail'
        }
      else
        mappings = {}
      end

      # Guarantees that none is left behind.
      source.list('', '*').each do |f|
        mappings[f.name] = f.name unless mappings[f.name]
      end

      # Loop through folders and copy messages.
      mappings.each do |source_folder, dest_folder|

        transfer = "#{soruce_folder} => #{dest_folder}"
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

        # Build a lookup hash of all message ids present in the destination folder.
        dest_info = {}

        dd 'analyzing existing messages...'
        uids = dest.uid_search(['ALL'])
        dd "found #{uids.length} messages"
        @report[transfer][:source] = uids.length
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

        # Loop through all messages in the source folder.
        uids = source.uid_search(['ALL'])
        ds "found #{uids.length} messages"

        @report[transfer][:dest] = uids.length
        @report[transfer][:transfered] = 0

        if uids.length > 0
          uid_fetch_block(source, uids, ['ENVELOPE']) do |data|
            mid = data.attr['ENVELOPE'].message_id

            # If this message is already in the destination folder, skip it.
            next if dest_info[mid]

            # Download the full message body from the source folder.
            ds "downloading message #{mid}..."
            msg = source.uid_fetch(data.attr['UID'], ['RFC822', 'FLAGS', 'INTERNALDATE']).first

            # Append the message to the destination folder, preserving flags and internal timestamp.
            dd "storing message #{mid}..."
            success = false
            begin
              dest.append(dest_folder, msg.attr['RFC822'], msg.attr['FLAGS'], msg.attr['INTERNALDATE'])
              success = true
              @report[transfer][:transfered] += 1
            rescue Net::IMAP::NoResponseError => e
              puts "Got exception: #{e.message}. Retrying..."
              sleep 1
            end until success
          end
        end

        source.close
        dest.close
      end
      
      email = ERB.new(File.read('view/email.erb'))

      Pony.mail :to => params['source_email'],
            :from => "lamigra@officina.me",
            :subject => "Migração Completa!",
            :body => email.result(binding)
    end

		protected
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
