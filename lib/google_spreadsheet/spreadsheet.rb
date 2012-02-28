# Author: Hiroshi Ichikawa <http://gimite.net/>
# The license of this source is "New BSD Licence"

require "google_spreadsheet/util"
require "google_spreadsheet/error"
require "google_spreadsheet/worksheet"
require "google_spreadsheet/table"


module GoogleSpreadsheet

    # Use methods in GoogleSpreadsheet::Session to get GoogleSpreadsheet::Spreadsheet object.
    class Spreadsheet

        include(Util)
        
        SUPPORTED_EXPORT_FORMAT = Set.new(["xls", "csv", "pdf", "ods", "tsv", "html"])

        def initialize(session, worksheets_feed_url, title = nil) #:nodoc:
          @session = session
          @worksheets_feed_url = worksheets_feed_url
          @title = title
          @acls = []
          @acl_batch_url = ""
        end

        # URL of worksheet-based feed of the spreadsheet.
        attr_reader(:worksheets_feed_url)

        # Title of the spreadsheet.
        #
        # Set params[:reload] to true to force reloading the title.
        def title(params = {})
          if !@title || params[:reload]
            @title = spreadsheet_feed_entry(params).css("title").text
          end
          return @title
        end

        def acl_feed_url
          document_feed_entry.css("[@rel='http://schemas.google.com/acl/2007#accessControlList']")[0]["href"]
        end

        def resource_id
          acl_feed_url =~ %r{^https?://docs.google.com/feeds/acl/private/full/(.*)\?.*$}
          return $1
        end

        # Key of the spreadsheet.
        def key
          if !(@worksheets_feed_url =~
              %r{^https?://spreadsheets.google.com/feeds/worksheets/(.*)/private/.*$})
            raise(GoogleSpreadsheet::Error,
              "worksheets feed URL is in unknown format: #{@worksheets_feed_url}")
          end
          return $1
        end
        
        # Spreadsheet feed URL of the spreadsheet.
        def spreadsheet_feed_url
          return "https://spreadsheets.google.com/feeds/spreadsheets/private/full/#{self.key}"
        end
        
        # URL which you can open the spreadsheet in a Web browser with.
        #
        # e.g. "http://spreadsheets.google.com/ccc?key=pz7XtlQC-PYx-jrVMJErTcg"
        def human_url
          # Uses Document feed because Spreadsheet feed returns wrong URL for Apps account.
          return self.document_feed_entry.css("link[@rel='alternate']")[0]["href"]
        end

        # DEPRECATED: Table and Record feeds are deprecated and they will not be available after
        # March 2012.
        #
        # Tables feed URL of the spreadsheet.
        def tables_feed_url
          warn(
              "DEPRECATED: Google Spreadsheet Table and Record feeds are deprecated and they " +
              "will not be available after March 2012.")
          return "https://spreadsheets.google.com/feeds/#{self.key}/tables"
        end

        # URL of feed used in document list feed API.
        def document_feed_url
          return "https://docs.google.com/feeds/documents/private/full/spreadsheet%3A#{self.key}"
        end

        # <entry> element of spreadsheet feed as Nokogiri::XML::Element.
        #
        # Set params[:reload] to true to force reloading the feed.
        def spreadsheet_feed_entry(params = {})
          if !@spreadsheet_feed_entry || params[:reload]
            @spreadsheet_feed_entry =
                @session.request(:get, self.spreadsheet_feed_url).css("entry")[0]
          end
          return @spreadsheet_feed_entry
        end
        
        # <entry> element of document list feed as Nokogiri::XML::Element.
        #
        # Set params[:reload] to true to force reloading the feed.
        def document_feed_entry(params = {})
          if !@document_feed_entry || params[:reload]
            @document_feed_entry =
                @session.request(:get, self.document_feed_url, :auth => :writely).css("entry")[0]
          end
          return @document_feed_entry
        end
        
        # Creates copy of this spreadsheet with the given title.
        def duplicate(new_title = nil)
          new_title ||= (self.title ? "Copy of " + self.title : "Untitled")
          post_url = "https://docs.google.com/feeds/default/private/full/"
          header = {"GData-Version" => "3.0", "Content-Type" => "application/atom+xml"}
          xml = <<-"EOS"
            <entry xmlns='http://www.w3.org/2005/Atom'>
              <id>#{h(self.document_feed_url)}</id>
              <title>#{h(new_title)}</title>
            </entry>
          EOS
          doc = @session.request(
              :post, post_url, :data => xml, :header => header, :auth => :writely)
          ss_url = doc.css(
              "link[@rel='http://schemas.google.com/spreadsheets/2006#worksheetsfeed']")[0]["href"]
          return Spreadsheet.new(@session, ss_url, new_title)
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
          doc = @session.request(:get, self.document_feed_url, :auth => :writely)
          edit_url = doc.css("link[@rel='edit']").first["href"]
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

          @session.request(:put, edit_url, :data => xml, :auth => :writely)
        end
        
        alias title= rename
        
        # Exports the spreadsheet in +format+ and returns it as String.
        #
        # +format+ can be either "xls", "csv", "pdf", "ods", "tsv" or "html".
        # In format such as "csv", only the worksheet specified with +worksheet_index+ is
        def export_as_string(format, worksheet_index = nil)
          gid_param = worksheet_index ? "&gid=#{worksheet_index}" : ""
          url =
              "https://spreadsheets.google.com/feeds/download/spreadsheets/Export" +
              "?key=#{key}&exportFormat=#{format}#{gid_param}"
          return @session.request(:get, url, :response_type => :raw)
        end
        
        # Exports the spreadsheet in +format+ as a local file.
        #
        # +format+ can be either "xls", "csv", "pdf", "ods", "tsv" or "html".
        # If +format+ is nil, it is guessed from the file name.
        # In format such as "csv", only the worksheet specified with +worksheet_index+ is exported.
        def export_as_file(local_path, format = nil, worksheet_index = nil)
          if !format
            format = File.extname(local_path).gsub(/^\./, "")
            if !SUPPORTED_EXPORT_FORMAT.include?(format)
              raise(ArgumentError,
                  ("Cannot guess format from the file name: %s\n" +
                   "Specify format argument explicitly.") %
                  local_path)
            end
          end
          open(local_path, "wb") do |f|
            f.write(export_as_string(format, worksheet_index))
          end
        end
        
        # Returns worksheets of the spreadsheet as array of GoogleSpreadsheet::Worksheet.
        def worksheets
          doc = @session.request(:get, @worksheets_feed_url)
          result = []
          doc.css("entry").each() do |entry|
            title = entry.css("title").text
            url = entry.css(
              "link[@rel='http://schemas.google.com/spreadsheets/2006#cellsfeed']")[0]["href"]
            result.push(Worksheet.new(@session, self, url, title))
          end
          return result.freeze()
        end
        
        # Returns a GoogleSpreadsheet::Worksheet with the given title in the spreadsheet.
        #
        # Returns nil if not found. Returns the first one when multiple worksheets with the
        # title are found.
        def worksheet_by_title(title)
          return self.worksheets.find(){ |ws| ws.title == title }
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
          url = doc.css(
            "link[@rel='http://schemas.google.com/spreadsheets/2006#cellsfeed']")[0]["href"]
          return Worksheet.new(@session, self, url, title)
        end

        def acls
          load_acls if (@acls.empty? || @acl_batch_url.empty?)
          @acls
        end

        def add_acl(scope, scope_type, role="reader")
          load_acls if (@acl_batch_url.empty? || @acls.size == 0)
          h = { scope: scope, type: scope_type, role: role }

          @acl = Acl.new(@session, self, h)
          save_acl(@acl)

          @acls.push @acl
        end

        # DEPRECATED: Table and Record feeds are deprecated and they will not be available after
        # March 2012.
        #
        # Returns list of tables in the spreadsheet.
        def tables
          warn(
              "DEPRECATED: Google Spreadsheet Table and Record feeds are deprecated and they " +
              "will not be available after March 2012.")
          doc = @session.request(:get, self.tables_feed_url)
          return doc.css("entry").map(){ |e| Table.new(@session, e) }.freeze()
        end
        
        def inspect
          fields = {:worksheets_feed_url => self.worksheets_feed_url}
          fields[:title] = @title if @title
          return "\#<%p %s>" % [self.class, fields.map(){ |k, v| "%s=%p" % [k, v] }.join(", ")]
        end

        private
        def load_acls
          doc = @session.request(:get, acl_feed_url)
          @acl_batch_url = href_from_rel(doc.root,"http://schemas.google.com/g/2005#batch")
          @acls = doc.root.xpath("./xmlns:entry").map {|e| Acl.new(@session,self, e)}
        end

        def save_acl(acl)
          header = {"GData-Version" => "3.0", "Content-Type" => "application/atom+xml"}

          save_url = "https://docs.google.com/feeds/default/private/full/#{self.resource_id}/acl"
          xml = <<-EOS
          <entry xmlns="http://www.w3.org/2005/Atom" xmlns:gAcl='http://schemas.google.com/acl/2007'>
            <category scheme='http://schemas.google.com/g/2005#kind'
              term='http://schemas.google.com/acl/2007#accessRule'/>
            <gAcl:role value='#{acl.role}'/>
            <gAcl:scope type='#{acl.scope_type}' value='#{acl.scope}'/>
          </entry>
          EOS

          @session.request(:post, save_url, data: xml, header: header, auth: :writely, )
        end

    end
    
end
