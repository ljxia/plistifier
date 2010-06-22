require 'plistifier/plist_encoding'
require 'rails_extensions'

Mime::Type.register "application/plist", :plist

# add support for plist
ActionController::Base.param_parsers[Mime::Type.lookup('application/plist')] = Proc.new do |data|
  #turn data into a hash of attributes      
  if data
    plist = CFPropertyList::List.new(:data => data)
    plist_data = CFPropertyList.native_types(plist.value)
    plist_data
  else
    data
  end
end