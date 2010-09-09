# Author: Hiroshi Ichikawa <http://gimite.net/>
# The license of this source is "New BSD Licence"

require "enumerator"
require "set"
require "net/https"
require "open-uri"
require "cgi"
require "uri"
require "rubygems"
require "hpricot"
require "oauth"
Net::HTTP.version_1_2

module GoogleSpreadsheet
    
    # Authenticates with given +mail+ and +password+, and returns GoogleSpreadsheet::Session
    # if succeeds. Raises GoogleSpreadsheet::AuthenticationError if fails.
    # Google Apps account is supported.
    def self.login(mail, password)
      return Session.login(mail, password)
    end

    # Authenticates with given OAuth token.
    #
    # For generating oauth_token, you can proceed as follow:
    #
    # 1) First generate OAuth consumer object with key and secret for your site by registering site with google
    #   @consumer = OAuth::Consumer.new( "key","secret", {:site=>"https://agree2"})
    # 2) Request token with OAuth
    #   @request_token = @consumer.get_request_token
    #   session[:request_token] = @request_token
    #   redirect_to @request_token.authorize_url
    # 3) Create an oauth access token
    #   @oauth_access_token = @request_token.get_access_token
    #   @access_token = OAuth::AccessToken.new(@consumer, @oauth_access_token.token, @oauth_access_token.secret)
    #
    # See these documents for details:
    #
    # - http://oauth.rubyforge.org/
    # - http://code.google.com/apis/accounts/docs/OAuth.html
    def self.login_with_oauth(oauth_token)
      return Session.login_with_oauth(oauth_token)
    end

    # Restores GoogleSpreadsheet::Session from +path+ and returns it.
    # If +path+ doesn't exist or authentication has failed, prompts mail and password on console,
    # authenticates with them, stores the session to +path+ and returns it.
    #
    # This method requires Highline library: http://rubyforge.org/projects/highline/
    def self.saved_session(path = ENV["HOME"] + "/.ruby_google_spreadsheet.token")
      tokens = {}
      if File.exist?(path)
        open(path) do |f|
          for auth in [:wise, :writely]
            line = f.gets()
            tokens[auth] = line && line.chomp()
          end
        end
      end
      session = Session.new(tokens)
      session.on_auth_fail = proc() do
        begin
          require "highline"
        rescue LoadError
          raise(LoadError,
            "GoogleSpreadsheet.saved_session requires Highline library.\n" +
            "Run\n" +
            "  \$ sudo gem install highline\n" +
            "to install it.")
        end
        highline = HighLine.new()
        mail = highline.ask("Mail: ")
        password = highline.ask("Password: "){ |q| q.echo = false }
        session.login(mail, password)
        open(path, "w", 0600) do |f|
          f.puts(session.auth_token(:wise))
          f.puts(session.auth_token(:writely))
        end
        true
      end
      if !session.auth_token
        session.on_auth_fail.call()
      end
      return session
    end
    
    
    module Util #:nodoc:
      
      module_function
        
        def encode_query(params)
          return params.map(){ |k, v| CGI.escape(k) + "=" + CGI.escape(v) }.join("&")
        end
        
        def h(str)
          return CGI.escapeHTML(str.to_s())
        end
        
        def as_utf8(str)
          if str.respond_to?(:force_encoding)
            str.force_encoding("UTF-8")
          else
            str
          end
        end
        
    end
    
    
    # Raised when spreadsheets.google.com has returned error.
    class Error < RuntimeError
        
    end
    
    
    # Raised when GoogleSpreadsheet.login has failed.
    class AuthenticationError < GoogleSpreadsheet::Error
        
    end
    
    # Raised when Google Spreadsheets gives you back a 
    # "Token invalid - AuthSub token has wrong scope" page
    class AuthSubTokenError < GoogleSpreadsheet::Error
    end

    # Use GoogleSpreadsheet.login or GoogleSpreadsheet.saved_session to get
    # GoogleSpreadsheet::Session object.
    class Session
        
        include(Util)
        extend(Util)
        
        # The same as GoogleSpreadsheet.login.
        def self.login(mail, password)
          session = Session.new()
          session.login(mail, password)
          return session
        end

        # The same as GoogleSpreadsheet.login_with_oauth.
        def self.login_with_oauth(oauth_token)
          session = Session.new(nil, oauth_token)
        end

        # Restores session using return value of auth_tokens method of previous session.
        def initialize(auth_tokens = nil, oauth_token = nil)
          @oauth_token = oauth_token
          @auth_tokens = auth_tokens || {}
        end

        # Authenticates with given +mail+ and +password+, and updates current session object
        # if succeeds. Raises GoogleSpreadsheet::AuthenticationError if fails.
        # Google Apps account is supported.
        def login(mail, password)
          begin
            @auth_tokens = {}
            authenticate(mail, password, :wise)
            authenticate(mail, password, :writely)
          rescue GoogleSpreadsheet::Error => ex
            return true if @on_auth_fail && @on_auth_fail.call()
            raise(AuthenticationError, "authentication failed for #{mail}: #{ex.message}")
          end
        end
        
        # Authentication tokens.
        attr_reader(:auth_tokens)
        
        # Authentication token.
        def auth_token(auth = :wise)
          return @auth_tokens[auth]
        end
        
        # Proc or Method called when authentication has failed.
        # When this function returns +true+, it tries again.
        attr_accessor :on_auth_fail
        
        def auth_header(auth) #:nodoc:
          token = auth == :none ? nil : @auth_tokens[auth]
          if token
            return {"Authorization" => "GoogleLogin auth=#{token}"}
          else
            return {}
          end
        end

        # Returns list of spreadsheets for the user as array of GoogleSpreadsheet::Spreadsheet.
        # You can specify query parameters described at
        # http://code.google.com/apis/spreadsheets/docs/2.0/reference.html#Parameters
        #
        # e.g.
        #   session.spreadsheets
        #   session.spreadsheets("title" => "hoge")
        def spreadsheets(params = {})
          query = encode_query(params)
          doc = request(:get, "https://spreadsheets.google.com/feeds/spreadsheets/private/full?#{query}")
          result = []
          for entry in doc.search("entry")
            title = as_utf8(entry.search("title").text)
            url = as_utf8(entry.search(
              "link[@rel='http://schemas.google.com/spreadsheets/2006#worksheetsfeed']")[0]["href"])
            result.push(Spreadsheet.new(self, url, title))
          end
          return result
        end
        
        # Returns GoogleSpreadsheet::Spreadsheet with given +key+.
        #
        # e.g.
        #   # http://spreadsheets.google.com/ccc?key=pz7XtlQC-PYx-jrVMJErTcg&hl=ja
        #   session.spreadsheet_by_key("pz7XtlQC-PYx-jrVMJErTcg")
        def spreadsheet_by_key(key)
          url = "https://spreadsheets.google.com/feeds/worksheets/#{key}/private/full"
          return Spreadsheet.new(self, url)
        end
        
        # Returns GoogleSpreadsheet::Spreadsheet with given +url+. You must specify either of:
        # - URL of the page you open to access the spreadsheet in your browser
        # - URL of worksheet-based feed of the spreadseet
        #
        # e.g.
        #   session.spreadsheet_by_url(
        #     "http://spreadsheets.google.com/ccc?key=pz7XtlQC-PYx-jrVMJErTcg&hl=en")
        #   session.spreadsheet_by_url(
        #     "https://spreadsheets.google.com/feeds/worksheets/pz7XtlQC-PYx-jrVMJErTcg/private/full")
        def spreadsheet_by_url(url)
          # Tries to parse it as URL of human-readable spreadsheet.
          uri = URI.parse(url)
          if uri.host == "spreadsheets.google.com" && uri.path =~ /\/ccc$/
            if (uri.query || "").split(/&/).find(){ |s| s=~ /^key=(.*)$/ }
              return spreadsheet_by_key($1)
            end
          end
          # Assumes the URL is worksheets feed URL.
          return Spreadsheet.new(self, url)
        end
        
        # Returns GoogleSpreadsheet::Worksheet with given +url+.
        # You must specify URL of cell-based feed of the worksheet.
        #
        # e.g.
        #   session.worksheet_by_url(
        #     "http://spreadsheets.google.com/feeds/cells/pz7XtlQC-PYxNmbBVgyiNWg/od6/private/full")
        def worksheet_by_url(url)
          return Worksheet.new(self, nil, url)
        end
        
        # Creates new spreadsheet and returns the new GoogleSpreadsheet::Spreadsheet.
        #
        # e.g.
        #   session.create_spreadsheet("My new sheet")
        def create_spreadsheet(
            title = "Untitled",
            feed_url = "https://docs.google.com/feeds/documents/private/full")
          xml = <<-"EOS"
            <atom:entry xmlns:atom="http://www.w3.org/2005/Atom" xmlns:docs="http://schemas.google.com/docs/2007">
              <atom:category scheme="http://schemas.google.com/g/2005#kind"
                  term="http://schemas.google.com/docs/2007#spreadsheet" label="spreadsheet"/>
              <atom:title>#{h(title)}</atom:title>
            </atom:entry>
          EOS

          doc = request(:post, feed_url, :data => xml, :auth => :writely)
          ss_url = nil
          found_item = doc.search(
            "link[@rel='http://schemas.google.com/spreadsheets/2006#worksheetsfeed']")
          if found_item && found_item[0]
            ss_url = as_utf8(found_item[0]["href"])
            return Spreadsheet.new(self, ss_url, title)
          else
            raise Error, "Could not find link to worksheetsfeed (found_item was #{found_item}) in #{doc.to_html}"
          end
        end
        
        def request(method, url, params = {}) #:nodoc:
          # Always uses HTTPS.
          url = url.gsub(%r{^http://}, "https://")
          uri = URI.parse(url)
          data = params[:data]
          auth = params[:auth] || :wise
          if params[:header]
            add_header = params[:header]
          else
            add_header = data ? {"Content-Type" => "application/atom+xml"} : {}
          end
          response_type = params[:response_type] || :xml
          
          if @oauth_token
            
            if method == :delete || method == :get
              response = @oauth_token.__send__(method, url, add_header)
            else
              response = @oauth_token.__send__(method, url, data, add_header)
            end
            check_for_errors(response)
            return convert_response(response, response_type)
            
          else
            
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = true
            http.verify_mode = OpenSSL::SSL::VERIFY_NONE
            http.start() do
              while true
                path = uri.path + (uri.query ? "?#{uri.query}" : "")
                header = auth_header(auth).merge(add_header)
                if method == :delete || method == :get
                  response = http.__send__(method, path, header)
                else
                  response = http.__send__(method, path, data, header)
                end
                if response.code == "401" && @on_auth_fail && @on_auth_fail.call()
                  next
                end
                if !(response.code =~ /^2/)
                  raise(
                    response.code == "401" ? AuthenticationError : GoogleSpreadsheet::Error,
                    "Response code #{response.code} for #{method} #{url}: " +
                    CGI.unescapeHTML(response.body))
                end

                check_for_errors(response)
                return convert_response(response, response_type)
              end
            end
            
          end
        end
        
      private

        # checks for various errors and throws if an error is found.
        # meant to be chainable, so return the response back
        def check_for_errors(response)
          if response.body =~ /Token invalid - AuthSub token has wrong scope/
            raise AuthSubTokenError, "Token invalid, HTML returned was #{response.body}"
          end

          unless response.status == Net::HTTPSuccess
            raise Net::HTTPBadResponse,
                "status: #{response.header['status']}\nbody: #{response.body}"
          end
          return response
        end

        def convert_response(response, response_type)
          case response_type
            when :xml
              return Hpricot.XML(response.body)
            when :raw
              return response.body
            else
              raise("unknown params[:response_type]: %s" % response_type)
          end
        end
        
        def authenticate(mail, password, auth)
          params = {
            "accountType" => "HOSTED_OR_GOOGLE",
            "Email" => mail,
            "Passwd" => password,
            "service" => auth.to_s(),
            "source" => "Gimite-RubyGoogleSpreadsheet-1.00",
          }
          response = request(:post,
            "https://www.google.com/accounts/ClientLogin",
            :data => encode_query(params), :auth => :none, :header => {}, :response_type => :raw)
          @auth_tokens[auth] = response.slice(/^Auth=(.*)$/, 1)
        end
        
    end
    
    
    # Use methods in GoogleSpreadsheet::Session to get GoogleSpreadsheet::Spreadsheet object.
    class Spreadsheet
        
        include(Util)
        
        def initialize(session, worksheets_feed_url, title = nil) #:nodoc:
          @session = session
          @worksheets_feed_url = worksheets_feed_url
          @title = title
        end
        
        # URL of worksheet-based feed of the spreadsheet.
        attr_reader(:worksheets_feed_url)
        
        # Title of the spreadsheet. So far only available if you get this object by
        # GoogleSpreadsheet::Session#spreadsheets.
        attr_reader(:title)
        
        # Key of the spreadsheet.
        def key
          if !(@worksheets_feed_url =~
              %r{^https?://spreadsheets.google.com/feeds/worksheets/(.*)/private/full$})
            raise(GoogleSpreadsheet::Error,
              "worksheets feed URL is in unknown format: #{@worksheets_feed_url}")
          end
          return $1
        end
        
        # Tables feed URL of the spreadsheet.
        def tables_feed_url
          return "https://spreadsheets.google.com/feeds/#{self.key}/tables"
        end

        # URL of feed used in document list feed API.
        def document_feed_url
          return "https://docs.google.com/feeds/documents/private/full/spreadsheet%3A#{self.key}"
        end

        # Creates copy of this spreadsheet with the given name.
        def duplicate(new_name = nil)
          new_name ||= (@title ? "Copy of " + @title : "Untitled")
          get_url = "https://spreadsheets.google.com/feeds/download/spreadsheets/Export?key=#{key}&exportFormat=ods"
          ods = @session.request(:get, get_url, :response_type => :raw)
          
          url = "https://docs.google.com/feeds/documents/private/full"
          header = {
            "Content-Type" => "application/x-vnd.oasis.opendocument.spreadsheet",
            "Slug" => URI.encode(new_name),
          }
          doc = @session.request(:post, url, :data => ods, :auth => :writely, :header => header)
          ss_url = as_utf8(doc.search(
            "link[@rel='http://schemas.google.com/spreadsheets/2006#worksheetsfeed']")[0]["href"])
          return Spreadsheet.new(@session, ss_url, title)
        end
        
        # If +permanent+ is +false+, moves the spreadsheet to the trash.
        # If +permanent+ is +true+, deletes the spreadsheet permanently.
        def delete(permanent = false)
          @session.request(:delete,
            self.document_feed_url + (permanent ? "?delete=true" : ""),
            :auth => :writely, :header => {"If-Match" => "*"})
        end
        
        # Renames title of the spreadsheet.
        def rename(title)
          doc = @session.request(:get, self.document_feed_url)
          edit_url = doc.search("link[@rel='edit']")[0]["href"]
          xml = <<-"EOS"
            <atom:entry
                xmlns:atom="http://www.w3.org/2005/Atom"
                xmlns:docs="http://schemas.google.com/docs/2007">
              <atom:category
                scheme="http://schemas.google.com/g/2005#kind"
                term="http://schemas.google.com/docs/2007#spreadsheet" label="spreadsheet"/>
              <atom:title>#{h(title)}</atom:title>
            </atom:entry>
          EOS

          @session.request(:put, edit_url, :data => xml)
        end
        
        # Returns worksheets of the spreadsheet as array of GoogleSpreadsheet::Worksheet.
        def worksheets
          doc = @session.request(:get, @worksheets_feed_url)
          result = []
          for entry in doc.search("entry")
            title = as_utf8(entry.search("title").text)
            url = as_utf8(entry.search(
              "link[@rel='http://schemas.google.com/spreadsheets/2006#cellsfeed']")[0]["href"])
            result.push(Worksheet.new(@session, self, url, title))
          end
          return result.freeze()
        end
        
        # Adds a new worksheet to the spreadsheet. Returns added GoogleSpreadsheet::Worksheet.
        def add_worksheet(title, max_rows = 100, max_cols = 20)
          xml = <<-"EOS"
            <entry xmlns='http://www.w3.org/2005/Atom'
                   xmlns:gs='http://schemas.google.com/spreadsheets/2006'>
              <title>#{h(title)}</title>
              <gs:rowCount>#{h(max_rows)}</gs:rowCount>
              <gs:colCount>#{h(max_cols)}</gs:colCount>
            </entry>
          EOS
          doc = @session.request(:post, @worksheets_feed_url, :data => xml)
          url = as_utf8(doc.search(
            "link[@rel='http://schemas.google.com/spreadsheets/2006#cellsfeed']")[0]["href"])
          return Worksheet.new(@session, self, url, title)
        end
        
        # Returns list of tables in the spreadsheet.
        def tables
          doc = @session.request(:get, self.tables_feed_url)
          return doc.search("entry").map(){ |e| Table.new(@session, e) }.freeze()
        end
        
    end
    
    # Use GoogleSpreadsheet::Worksheet#add_table to create table.
    # Use GoogleSpreadsheet::Worksheet#tables to get GoogleSpreadsheet::Table objects.
    class Table
        
        include(Util)

        def initialize(session, entry) #:nodoc:
          @columns = {}
          @worksheet_title = as_utf8(entry.search("gs:worksheet")[0]["name"])
          @records_url = as_utf8(entry.search("content")[0]["src"])
          @session = session
        end
        
        # Title of the worksheet the table belongs to.
        attr_reader(:worksheet_title)

        # Adds a record.
        def add_record(values)
          fields = ""
          values.each do |name, value|
            fields += "<gs:field name='#{h(name)}'>#{h(value)}</gs:field>"
          end
          xml =<<-EOS
            <entry
                xmlns="http://www.w3.org/2005/Atom"
                xmlns:gs="http://schemas.google.com/spreadsheets/2006">
              #{fields}
            </entry>
          EOS
          @session.request(:post, @records_url, :data => xml)
        end
        
        # Returns records in the table.
        def records
          doc = @session.request(:get, @records_url)
          return doc.search("entry").map(){ |e| Record.new(@session, e) }
        end
        
    end
    
    # Use GoogleSpreadsheet::Table#records to get GoogleSpreadsheet::Record objects.
    class Record < Hash
        
        def initialize(session, entry) #:nodoc:
          @session = session
          for field in entry.search("gs:field")
            self[as_utf8(field["name"])] = as_utf8(field.inner_text)
          end
        end
        
        def inspect #:nodoc:
          content = self.map(){ |k, v| "%p => %p" % [k, v] }.join(", ")
          return "\#<%p:{%s}>" % [self.class, content]
        end
        
    end
    
    # Use GoogleSpreadsheet::Spreadsheet#worksheets to get GoogleSpreadsheet::Worksheet object.
    class Worksheet
        
        include(Util)
        
        def initialize(session, spreadsheet, cells_feed_url, title = nil) #:nodoc:
          @session = session
          @spreadsheet = spreadsheet
          @cells_feed_url = cells_feed_url
          @title = title
          
          @cells = nil
          @input_values = nil
          @modified = Set.new()
        end

        # URL of cell-based feed of the worksheet.
        attr_reader(:cells_feed_url)
        
        # URL of worksheet feed URL of the worksheet.
        def worksheet_feed_url
          # I don't know good way to get worksheet feed URL from cells feed URL.
          # Probably it would be cleaner to keep worksheet feed URL and get cells feed URL
          # from it.
          if !(@cells_feed_url =~
              %r{^https?://spreadsheets.google.com/feeds/cells/(.*)/(.*)/private/full$})
            raise(GoogleSpreadsheet::Error,
              "cells feed URL is in unknown format: #{@cells_feed_url}")
          end
          return "https://spreadsheets.google.com/feeds/worksheets/#{$1}/private/full/#{$2}"
        end
        
        # GoogleSpreadsheet::Spreadsheet which this worksheet belongs to.
        def spreadsheet
          if !@spreadsheet
            if !(@cells_feed_url =~
                %r{^https?://spreadsheets.google.com/feeds/cells/(.*)/(.*)/private/full$})
              raise(GoogleSpreadsheet::Error,
                "cells feed URL is in unknown format: #{@cells_feed_url}")
            end
            @spreadsheet = @session.spreadsheet_by_key($1)
          end
          return @spreadsheet
        end
        
        # Returns content of the cell as String. Top-left cell is [1, 1].
        def [](row, col)
          return self.cells[[row, col]] || ""
        end
        
        # Updates content of the cell.
        # Note that update is not sent to the server until you call save().
        # Top-left cell is [1, 1].
        #
        # e.g.
        #   worksheet[2, 1] = "hoge"
        #   worksheet[1, 3] = "=A1+B1"
        def []=(row, col, value)
          reload() if !@cells
          @cells[[row, col]] = value
          @input_values[[row, col]] = value
          @modified.add([row, col])
          self.max_rows = row if row > @max_rows
          self.max_cols = col if col > @max_cols
        end
        
        # Returns the value or the formula of the cell. Top-left cell is [1, 1].
        #
        # If user input "=A1+B1" to cell [1, 3], worksheet[1, 3] is "3" for example and
        # worksheet.input_value(1, 3) is "=RC[-2]+RC[-1]".
        def input_value(row, col)
          reload() if !@cells
          return @input_values[[row, col]] || ""
        end
        
        # Row number of the bottom-most non-empty row.
        def num_rows
          reload() if !@cells
          return @cells.keys.map(){ |r, c| r }.max || 0
        end
        
        # Column number of the right-most non-empty column.
        def num_cols
          reload() if !@cells
          return @cells.keys.map(){ |r, c| c }.max || 0
        end
        
        # Number of rows including empty rows.
        def max_rows
          reload() if !@cells
          return @max_rows
        end
        
        # Updates number of rows.
        # Note that update is not sent to the server until you call save().
        def max_rows=(rows)
          reload() if !@cells
          @max_rows = rows
          @meta_modified = true
        end
        
        # Number of columns including empty columns.
        def max_cols
          reload() if !@cells
          return @max_cols
        end
        
        # Updates number of columns.
        # Note that update is not sent to the server until you call save().
        def max_cols=(cols)
          reload() if !@cells
          @max_cols = cols
          @meta_modified = true
        end
        
        # Title of the worksheet (shown as tab label in Web interface).
        def title
          reload() if !@title
          return @title
        end
        
        # Updates title of the worksheet.
        # Note that update is not sent to the server until you call save().
        def title=(title)
          reload() if !@cells
          @title = title
          @meta_modified = true
        end
        
        def cells #:nodoc:
          reload() if !@cells
          return @cells
        end
        
        # An array of spreadsheet rows. Each row contains an array of
        # columns. Note that resulting array is 0-origin so
        # worksheet.rows[0][0] == worksheet[1, 1].
        def rows(skip = 0)
          nc = self.num_cols
          result = ((1 + skip)..self.num_rows).map() do |row|
            (1..nc).map(){ |col| self[row, col] }.freeze()
          end
          return result.freeze()
        end
        
        # Reloads content of the worksheets from the server.
        # Note that changes you made by []= is discarded if you haven't called save().
        def reload()
          doc = @session.request(:get, @cells_feed_url)
          @max_rows = doc.search("gs:rowCount").text.to_i()
          @max_cols = doc.search("gs:colCount").text.to_i()
          @title = as_utf8(doc.search("/feed/title").text)
          
          @cells = {}
          @input_values = {}
          for entry in doc.search("entry")
            cell = entry.search("gs:cell")[0]
            row = cell["row"].to_i()
            col = cell["col"].to_i()
            @cells[[row, col]] = as_utf8(cell.inner_text)
            @input_values[[row, col]] = as_utf8(cell["inputValue"])
          end
          @modified.clear()
          @meta_modified = false
          return true
        end
        
        # Saves your changes made by []=, etc. to the server.
        def save()
          sent = false
          
          if @meta_modified
            
            ws_doc = @session.request(:get, self.worksheet_feed_url)
            edit_url = ws_doc.search("link[@rel='edit']")[0]["href"]
            xml = <<-"EOS"
              <entry xmlns='http://www.w3.org/2005/Atom'
                     xmlns:gs='http://schemas.google.com/spreadsheets/2006'>
                <title>#{h(self.title)}</title>
                <gs:rowCount>#{h(self.max_rows)}</gs:rowCount>
                <gs:colCount>#{h(self.max_cols)}</gs:colCount>
              </entry>
            EOS
            
            @session.request(:put, edit_url, :data => xml)
            
            @meta_modified = false
            sent = true
            
          end
          
          if !@modified.empty?
            
            # Gets id and edit URL for each cell.
            # Note that return-empty=true is required to get those info for empty cells.
            cell_entries = {}
            rows = @modified.map(){ |r, c| r }
            cols = @modified.map(){ |r, c| c }
            url = "#{@cells_feed_url}?return-empty=true&min-row=#{rows.min}&max-row=#{rows.max}" +
              "&min-col=#{cols.min}&max-col=#{cols.max}"
            doc = @session.request(:get, url)
            for entry in doc.search("entry")
              row = entry.search("gs:cell")[0]["row"].to_i()
              col = entry.search("gs:cell")[0]["col"].to_i()
              cell_entries[[row, col]] = entry
            end
            
            # Updates cell values using batch operation.
            # If the data is large, we split it into multiple operations, otherwise batch may fail.
            @modified.each_slice(250) do |chunk|
              
              xml = <<-EOS
                <feed xmlns="http://www.w3.org/2005/Atom"
                      xmlns:batch="http://schemas.google.com/gdata/batch"
                      xmlns:gs="http://schemas.google.com/spreadsheets/2006">
                  <id>#{h(@cells_feed_url)}</id>
              EOS
              for row, col in chunk
                value = @cells[[row, col]]
                entry = cell_entries[[row, col]]
                id = entry.search("id").text
                edit_url = entry.search("link[@rel='edit']")[0]["href"]
                xml << <<-EOS
                  <entry>
                    <batch:id>#{h(row)},#{h(col)}</batch:id>
                    <batch:operation type="update"/>
                    <id>#{h(id)}</id>
                    <link rel="edit" type="application/atom+xml"
                      href="#{h(edit_url)}"/>
                    <gs:cell row="#{h(row)}" col="#{h(col)}" inputValue="#{h(value)}"/>
                  </entry>
                EOS
              end
              xml << <<-"EOS"
                </feed>
              EOS
            
              result = @session.request(:post, "#{@cells_feed_url}/batch", :data => xml)
              for entry in result.search("atom:entry")
                interrupted = entry.search("batch:interrupted")[0]
                if interrupted
                  raise(GoogleSpreadsheet::Error, "Update has failed: %s" %
                    interrupted["reason"])
                end
                if !(entry.search("batch:status")[0]["code"] =~ /^2/)
                  raise(GoogleSpreadsheet::Error, "Updating cell %s has failed: %s" %
                    [entry.search("atom:id").text, entry.search("batch:status")[0]["reason"]])
                end
              end
              
            end
            
            @modified.clear()
            sent = true
            
          end
          return sent
        end
        
        # Calls save() and reload().
        def synchronize()
          save()
          reload()
        end
        
        # Deletes this worksheet. Deletion takes effect right away without calling save().
        def delete()
          ws_doc = @session.request(:get, self.worksheet_feed_url)
          edit_url = ws_doc.search("link[@rel='edit']")[0]["href"]
          @session.request(:delete, edit_url)
        end
        
        # Returns true if you have changes made by []= which haven't been saved.
        def dirty?
          return !@modified.empty?
        end
        
        # Creates table for the worksheet and returns GoogleSpreadsheet::Table.
        # See this document for details:
        # http://code.google.com/intl/en/apis/spreadsheets/docs/3.0/developers_guide_protocol.html#TableFeeds
        def add_table(table_title, summary, columns)
          column_xml = ""
          columns.each do |index, name|
            column_xml += "<gs:column index='#{h(index)}' name='#{h(name)}'/>\n"
          end

          xml = <<-"EOS"
            <entry xmlns="http://www.w3.org/2005/Atom"
              xmlns:gs="http://schemas.google.com/spreadsheets/2006">
              <title type='text'>#{h(table_title)}</title>
              <summary type='text'>#{h(summary)}</summary>
              <gs:worksheet name='#{h(self.title)}' />
              <gs:header row='1' />
              <gs:data numRows='0' startRow='2'>
                #{column_xml}
              </gs:data>
            </entry>
          EOS

          result = @session.request(:post, self.spreadsheet.tables_feed_url, :data => xml)
          return Table.new(@session, result)
        end
        
        # Returns list of tables for the workwheet.
        def tables
          return self.spreadsheet.tables.select(){ |t| t.worksheet_title == self.title }
        end

        # List feed URL of the worksheet.
        def list_feed_url
          # Gets the worksheets metafeed.
          entry = @session.request(:get, self.worksheet_feed_url)

          # Gets the URL of list-based feed for the given spreadsheet.
          return as_utf8(entry.search(
            "link[@rel='http://schemas.google.com/spreadsheets/2006#listfeed']")[0]["href"])
        end

    end
    
    
end
