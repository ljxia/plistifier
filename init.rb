require 'plistifier/plist_encoding'
require 'rails_extensions'

Mime::Type.register "application/plist", :plist

# add support for plist
ActionController::Base.param_parsers[Mime::Type.lookup('application/plist')] = Proc.new do |data|
  #turn data into a hash of attributes      
  plist = CFPropertyList::List.new(:data => data)
  data = CFPropertyList.native_types(plist.value)
  data
end