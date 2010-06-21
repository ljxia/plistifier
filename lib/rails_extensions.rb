require "cfpropertylist/rbCFPropertyList"

class Array
  def to_plist(options = {})
    options[:plist_format] ||= CFPropertyList::List::FORMAT_BINARY 
    
    array = []
    self.each do |a|
      if a.is_a? ActiveRecord::Base
        array << a.to_hash(options)
      else
        array << a
      end
    end
    
    plist = CFPropertyList::List.new
    plist.value = CFPropertyList.guess(array)
    plist.to_str(options[:plist_format])
  end  
end

class Hash
  def to_plist(options = {})
    options[:plist_format] ||= CFPropertyList::List::FORMAT_BINARY 
    
    hash = {}
    self.each_pair do |k,v|
      if v.is_a? ActiveRecord::Base
        hash[k] = v.to_hash(options)
      else
        hash[k] = v
      end
    end
    
    plist = CFPropertyList::List.new
    plist.value = CFPropertyList.guess(hash)
    plist.to_str(options[:plist_format])
  end  
end

module ActionController
  class Base
    def render_with_plist(options = nil, extra_options = {}, &block)      
      if options && options.is_a?(Hash) && plist = options[:plist]     
        if plist.is_a? Array
          filename = plist.first.class.name          
        else
          filename = "#{plist.class.name}-#{plist.id}"
        end
                
        send_data(
          plist,
          :type => Mime::PLIST, 
          :filename => "#{filename}.plist", 
          :disposition => 'inline'
        )
      else
        render_without_plist(options, extra_options, &block) 
      end
    end
    
    alias_method_chain :render, :plist
  end
end