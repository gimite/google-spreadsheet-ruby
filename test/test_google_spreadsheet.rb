$LOAD_PATH.unshift(File.dirname(__FILE__) + "/../lib")
require "rubygems"
require "bundler/setup"

require "test/unit"
require "google_spreadsheet"
require "highline"


class TC_GoogleSpreadsheet < Test::Unit::TestCase
    
    def test_all()
      puts("This test will create spreadsheets with your account, read/write them")
      puts("and finally delete them (if everything goes well).")
      use_saved_session = ENV["GOOGLE_SPREADSHEET_RUBY_USE_SAVED_SESSION"]
      if use_saved_session && !use_saved_session.empty?
        session = GoogleSpreadsheet.saved_session
      else
          unless session = login_from_fixtures
              highline = HighLine.new()
              mail = highline.ask("Mail: ")
              password = highline.ask("Password: "){ |q| q.echo = false }
              session = GoogleSpreadsheet.login(mail, password)
          end
      end
      
      ss_title = "google-spreadsheet-ruby test " + Time.now.strftime("%Y-%m-%d-%H-%M-%S")
      ss = session.create_spreadsheet(ss_title)
      assert_equal(ss_title, ss.title)
      
      ws = ss.worksheets[0]
      assert_equal(ss.worksheets_feed_url, ws.spreadsheet.worksheets_feed_url)
      ws.title = "hoge"
      ws.max_rows = 20
      ws.max_cols = 10
      ws[1, 1] = "3"
      ws[1, 2] = "5"
      ws[1, 3] = "=A1+B1"
      assert_equal(20, ws.max_rows)
      assert_equal(10, ws.max_cols)
      assert_equal(1, ws.num_rows)
      assert_equal(3, ws.num_cols)
      assert_equal("3", ws[1, 1])
      assert_equal("5", ws[1, 2])
      ws.save()
      
      ws.reload()
      assert_equal(20, ws.max_rows)
      assert_equal(10, ws.max_cols)
      assert_equal(1, ws.num_rows)
      assert_equal(3, ws.num_cols)
      assert_equal("3", ws[1, 1])
      assert_equal("5", ws[1, 2])
      assert_equal("8", ws[1, 3])
      if RUBY_VERSION >= "1.9.0"
        assert_equal(Encoding::UTF_8, ws[1, 1].encoding)
      end
      
      assert_equal("3\t5\t8", ss.export_as_string("tsv", 0))
      
      ss2 = session.spreadsheet_by_key(ss.key)
      assert_equal(ss_title, ss2.title)
      assert_equal(ss.worksheets_feed_url, ss2.worksheets_feed_url)
      assert_equal(ss.human_url, ss2.human_url)
      assert_equal("hoge", ss2.worksheets[0].title)
      assert_equal("3", ss2.worksheets[0][1, 1])
      if RUBY_VERSION >= "1.9.0"
        assert_equal(Encoding::UTF_8, ss2.title.encoding)
        assert_equal(Encoding::UTF_8, ss2.worksheets[0].title.encoding)
      end
      
      ss3 = session.spreadsheet_by_url("http://spreadsheets.google.com/ccc?key=#{ss.key}&hl=en")
      assert_equal(ss.worksheets_feed_url, ss3.worksheets_feed_url)
      ss4 = session.spreadsheet_by_url(ss.worksheets_feed_url)
      assert_equal(ss.worksheets_feed_url, ss4.worksheets_feed_url)
      
      assert_not_nil(session.spreadsheets.find(){ |s| s.title == ss_title })
      assert_not_nil(session.spreadsheets("title" => ss_title).
        find(){ |s| s.title == ss_title })
      
      ws2 = session.worksheet_by_url(ws.cells_feed_url)
      assert_equal(ws.cells_feed_url, ws2.cells_feed_url)
      assert_equal("hoge", ws2.title)
      
      ss_copy_title = "google-spreadsheet-ruby test copy " + Time.now.strftime("%Y-%m-%d-%H-%M-%S")
      ss_copy = ss.duplicate(ss_copy_title)
      assert_not_nil(session.spreadsheets("title" => ss_copy_title).
        find(){ |s| s.title == ss_copy_title })
      assert_equal("3", ss_copy.worksheets[0][1, 1])
      
      ss.delete()
      assert_nil(session.spreadsheets("title" => ss_title).
        find(){ |s| s.title == ss_title })
      ss_copy.delete(true)
      assert_nil(session.spreadsheets("title" => ss_copy_title).
        find(){ |s| s.title == ss_copy_title })
      ss.delete(true)
    end
    
    #######
    private
    #######

    def login_from_fixtures
      begin
          fixtures = YAML.load_file(File.join(File.dirname(__FILE__), 'account.yml'))
      rescue
          return false
      end
      GoogleSpreadsheet.login(fixtures["username"], fixtures['password'])
    end

end
