# Author: Hiroshi Ichikawa <http://gimite.net/>
# The license of this source is "New BSD Licence"

require "google_spreadsheet/util"
require "google_spreadsheet/error"
require "google_spreadsheet/spreadsheet"


module GoogleSpreadsheet

    # Use GoogleSpreadsheet::Session#collection_by_url to get GoogleSpreadsheet::Collection object.
    class Collection

        include(Util)
        
        def initialize(session, collection_feed_url) #:nodoc:
          @session = session
          self.collection_feed_url = collection_feed_url
        end
        
        # Adds the given GoogleSpreadsheet::Spreadsheet to the collection.
        def add(spreadsheet)
          contents_url = concat_url(self.collection_feed_url, "/contents")
          header = {"GData-Version" => "3.0", "Content-Type" => "application/atom+xml"}
          xml = <<-"EOS"
            <entry xmlns="http://www.w3.org/2005/Atom">
              <id>#{h(spreadsheet.document_feed_url)}</id>
            </entry>
          EOS
          @session.request(
              :post, contents_url, :data => xml, :header => header, :auth => :writely)
          return nil
        end

        # Returns all the spreadsheets in the collection.
        def spreadsheets
          contents_url = concat_url(self.collection_feed_url, "/contents")
          header = {"GData-Version" => "3.0", "Content-Type" => "application/atom+xml"}
          doc = @session.request(:get, contents_url, :header => header, :auth => :writely)

          return doc.css("feed > entry").map() do |entry|
            title = entry.css("title").text
            url = entry.css(
              "link[@rel='http://schemas.google.com/spreadsheets/2006#worksheetsfeed']")[0]["href"]
            GoogleSpreadsheet::Spreadsheet.new(@session, url, title)
          end
        end

        # Browrser's addressbar url covert to collection_feed_url
        def collection_feed_url=(url)
          if url.include? 'folders/'
            @collection_feed_url = "http://docs.google.com/feeds/default/private/full/folder%3A" + url.split('folders/')[-1]
          else
            @collection_feed_url = url
          end
        end

        def collection_feed_url
          @collection_feed_url
        end
        
        # TODO Add other operations.

    end
    
end
