Gem::Specification.new do |s|
  
  s.name = "google-spreadsheet-ruby"
  s.version = "0.3.0"
  s.authors = ["Hiroshi Ichikawa"]
  s.email = ["gimite+github@gmail.com"]
  s.summary = "This is a library to read/write Google Spreadsheet."
  s.description = "This is a library to read/write Google Spreadsheet."
  s.homepage = "https://github.com/gimite/google-spreadsheet-ruby"
  s.rubygems_version = "1.2.0"
  
  s.files = ["README.rdoc"] + Dir["lib/**/*"]
  s.require_paths = ["lib"]
  s.has_rdoc = true
  s.extra_rdoc_files = ["README.rdoc"] + Dir["doc_src/**/*"]
  s.rdoc_options = ["--main", "README.rdoc"]

  s.add_dependency("google_drive", [">= 0.3.0"])
  s.add_development_dependency("rake", [">= 0.8.0"])
  
end
