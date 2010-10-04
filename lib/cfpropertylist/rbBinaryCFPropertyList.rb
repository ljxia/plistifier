# -*- coding: utf-8 -*-
#
# CFPropertyList implementation
# parser class to read, manipulate and write binary property list files (plist(5)) as defined by Apple
#
# Author::    Christian Kruse (mailto:cjk@wwwtech.de)
# Copyright:: Copyright (c) 2010
# License::   Distributes under the same terms as Ruby

class String
  if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('1.8.7')
    def bytesize      
      self.length
    end
  end
end

class Hash
  if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('1.8.7')
    def count      
      self.size
    end
  end
end

class Array
  if Gem::Version.new(RUBY_VERSION) < Gem::Version.new('1.8.7')
    def count      
      self.size
    end
  end
end


module CFPropertyList
  class Binary
    # Read a binary plist file
    def load(opts)
      @unique_table = {}
      @count_objects = 0
      @string_size = 0
      @int_size = 0
      @misc_size = 0
      @object_refs = 0

      @written_object_count = 0
      @object_table = []
      @object_ref_size = 0

      @offsets = []

      fd = nil
      if(opts.has_key?(:file)) then
        fd = File.open(opts[:file],"rb")
        file = opts[:file]
      else
        fd = StringIO.new(opts[:data],"rb")
        file = "<string>"
      end

      # first, we read the trailer: 32 byte from the end
      fd.seek(-32,IO::SEEK_END)
      buff = fd.read(32)

      offset_size, object_ref_size, number_of_objects, top_object, table_offset = buff.unpack "x6CCx4Nx4Nx4N"

      # after that, get the offset table
      fd.seek(table_offset, IO::SEEK_SET)
      coded_offset_table = fd.read(number_of_objects * offset_size)
      raise CFFormatError.new("#{file}: Format error!") unless coded_offset_table.bytesize == number_of_objects * offset_size

      @count_objects = number_of_objects

      # decode offset table
      formats = ["","C*","n*","(H6)*","N*"]
      @offsets = coded_offset_table.unpack(formats[offset_size])
      if(offset_size == 3) then
        0.upto(@offsets.size-1) { |i| @offsets[i] = @offsets[i].to_i(16) }
      end

      @object_ref_size = object_ref_size
      val = read_binary_object_at(file,fd,top_object)

      fd.close
      return val
    end


    # Convert CFPropertyList to binary format; since we have to count our objects we simply unique CFDictionary and CFArray
    def to_str(opts={})
      @unique_table = {}
      @count_objects = 0
      @object_refs = 0

      @written_object_count = 0
      @object_table = []
      @object_ref_size = 0

      @offsets = []

      binary_str = "bplist00"

      @object_refs = count_object_refs(opts[:root])
      @object_ref_size = Binary.bytes_needed(@object_refs)

      opts[:root].to_binary(self)

      next_offset = 8
      offsets = @object_table.collect { |object| offset = next_offset; next_offset += object.bytesize; offset }
      binary_str << @object_table.join

      table_offset = next_offset
      offset_size = Binary.bytes_needed(table_offset)

      if offset_size < 8
        # Fast path: encode the entire offset array at once.
        binary_str << offsets.pack((%w(C n N N)[offset_size - 1]) + '*')
      else
        # Slow path: host may be little or big endian, must pack each offset
        # separately.
        offsets.each do |offset|
          binary_str << "#{Binary.pack_it_with_size(offset_size,offset)}"
        end
      end

      binary_str << [offset_size, @object_ref_size].pack("x6CC")
      binary_str << [@object_table.size].pack("x4N")
      binary_str << [0].pack("x4N")
      binary_str << [table_offset].pack("x4N")

      return binary_str
    end

    # read a „null” type (i.e. null byte, marker byte, bool value)
    def read_binary_null_type(length)
      case length
      when 0 then return 0 # null byte
      when 8 then return CFBoolean.new(false)
      when 9 then return CFBoolean.new(true)
      when 15 then return 15 # fill type
      end

      raise CFFormatError.new("unknown null type: #{length}")
    end
    protected :read_binary_null_type

    # read a binary int value
    def read_binary_int(fname,fd,length)
      raise CFFormatError.new("Integer greater than 8 bytes: #{length}") if length > 3

      nbytes = 1 << length

      val = nil
      buff = fd.read(nbytes)

      case length
      when 0 then
        val = buff.unpack("C")
        val = val[0]
      when 1 then
        val = buff.unpack("n")
        val = val[0]
      when 2 then
        val = buff.unpack("N")
        val = val[0]
      when 3
        hiword,loword = buff.unpack("NN")
        if (hiword & 0x80000000) != 0
          # 8 byte integers are always signed, and are negative when bit 63 is
          # set. Decoding into either a Fixnum or Bignum is tricky, however,
          # because the size of a Fixnum varies among systems, and Ruby
          # doesn't consider the number to be negative, and won't sign extend.
          val = -(2**63 - ((hiword & 0x7fffffff) << 32 | loword))
        else
          val = hiword << 32 | loword
        end
      end

      return CFInteger.new(val);
    end
    protected :read_binary_int

    # read a binary real value
    def read_binary_real(fname,fd,length)
      raise CFFormatError.new("Real greater than 8 bytes: #{length}") if length > 3

      nbytes = 1 << length
      val = nil
      buff = fd.read(nbytes)

      case length
      when 0 then # 1 byte float? must be an error
        raise CFFormatError.new("got #{length+1} byte float, must be an error!")
      when 1 then # 2 byte float? must be an error
        raise CFFormatError.new("got #{length+1} byte float, must be an error!")
      when 2 then
        val = buff.reverse.unpack("f")
        val = val[0]
      when 3 then
        val = buff.reverse.unpack("d")
        val = val[0]
      end

      return CFReal.new(val)
    end
    protected :read_binary_real

    # read a binary date value
    def read_binary_date(fname,fd,length)
      raise CFFormatError.new("Date greater than 8 bytes: #{length}") if length > 3

      nbytes = 1 << length
      val = nil
      buff = fd.read(nbytes)

      case length
      when 0 then # 1 byte CFDate is an error
        raise CFFormatError.new("#{length+1} byte CFDate, error")
      when 1 then # 2 byte CFDate is an error
        raise CFFormatError.new("#{length+1} byte CFDate, error")
      when 2 then
        val = buff.reverse.unpack("f")
        val = val[0]
      when 3 then
        val = buff.reverse.unpack("d")
        val = val[0]
      end

      return CFDate.new(val,CFDate::TIMESTAMP_APPLE)
    end
    protected :read_binary_date

    # Read a binary data value
    def read_binary_data(fname,fd,length)
      buff = "";
      buff = fd.read(length) if length > 0
      return CFData.new(buff,CFData::DATA_RAW)
    end
    protected :read_binary_data

    # Read a binary string value
    def read_binary_string(fname,fd,length)
      buff = ""
      buff = fd.read(length) if length > 0

      @unique_table[buff] = true unless @unique_table.has_key?(buff)
      return CFString.new(buff)
    end
    protected :read_binary_string

    # Convert the given string from one charset to another
    def Binary.charset_convert(str,from,to="UTF-8")
      return str.clone.force_encoding(from).encode(to) if str.respond_to?("encode")
      return Iconv.conv(to,from,str)
    end

    # Count characters considering character set
    def Binary.charset_strlen(str,charset="UTF-8")
      if str.respond_to?(:encode)
        size = str.length
      else
        utf8_str = Iconv.conv("UTF-8",charset,str)
        size = utf8_str.scan(/./mu).size
      end
      
      # UTF-16 code units in the range D800-DBFF are the beginning of
      # a surrogate pair, and count as one additional character for
      # length calculation.
      if charset =~ /^UTF-16/
        if str.respond_to?(:encode)
          str.bytes.to_a.each_slice(2) { |pair| size += 1 if (0xd8..0xdb).include?(pair[0]) }
        else
          str.split('').each_slice(2) { |pair| size += 1 if ("\xd8".."\xdb").include?(pair[0]) }
        end
      end
      
      return size
    end

    # Read a unicode string value, coded as UTF-16BE
    def read_binary_unicode_string(fname,fd,length)
      # The problem is: we get the length of the string IN CHARACTERS;
      # since a char in UTF-16 can be 16 or 32 bit long, we don't really know
      # how long the string is in bytes
      buff = fd.read(2*length)

      @unique_table[buff] = true unless @unique_table.has_key?(buff)
      return CFString.new(Binary.charset_convert(buff,"UTF-16BE","UTF-8"))
    end
    protected :read_binary_unicode_string

    # Read an binary array value, including contained objects
    def read_binary_array(fname,fd,length)
      ary = []

      # first: read object refs
      if(length != 0) then
        buff = fd.read(length * @object_ref_size)
        objects = buff.unpack(@object_ref_size == 1 ? "C*" : "n*")

        # now: read objects
        0.upto(length-1) do |i|
          object = read_binary_object_at(fname,fd,objects[i])
          ary.push object
        end
      end

      return CFArray.new(ary)
    end
    protected :read_binary_array

    # Read a dictionary value, including contained objects
    def read_binary_dict(fname,fd,length)
      dict = {}

      # first: read keys
      if(length != 0) then
        buff = fd.read(length * @object_ref_size)
        keys = buff.unpack(@object_ref_size == 1 ? "C*" : "n*")

        # second: read object refs
        buff = fd.read(length * @object_ref_size)
        objects = buff.unpack(@object_ref_size == 1 ? "C*" : "n*")

        # read real keys and objects
        0.upto(length-1) do |i|
          key = read_binary_object_at(fname,fd,keys[i])
          object = read_binary_object_at(fname,fd,objects[i])
          dict[key.value] = object
        end
      end

      return CFDictionary.new(dict)
    end
    protected :read_binary_dict

    # Read an object type byte, decode it and delegate to the correct reader function
    def read_binary_object(fname,fd)
      # first: read the marker byte
      buff = fd.read(1)

      object_length = buff.unpack("C*")
      object_length = object_length[0]  & 0xF

      buff = buff.unpack("H*")
      object_type = buff[0][0].chr

      if(object_type != "0" && object_length == 15) then
        object_length = read_binary_object(fname,fd)
        object_length = object_length.value
      end

      retval = nil
      case object_type
      when '0' then # null, false, true, fillbyte
        retval = read_binary_null_type(object_length)
      when '1' then # integer
        retval = read_binary_int(fname,fd,object_length)
      when '2' then # real
        retval = read_binary_real(fname,fd,object_length)
      when '3' then # date
        retval = read_binary_date(fname,fd,object_length)
      when '4' then # data
        retval = read_binary_data(fname,fd,object_length)
      when '5' then # byte string, usually utf8 encoded
        retval = read_binary_string(fname,fd,object_length)
      when '6' then # unicode string (utf16be)
        retval = read_binary_unicode_string(fname,fd,object_length)
      when 'a' then # array
        retval = read_binary_array(fname,fd,object_length)
      when 'd' then # dictionary
        retval = read_binary_dict(fname,fd,object_length)
      end

      return retval
    end
    protected :read_binary_object

    # Read an object type byte at position $pos, decode it and delegate to the correct reader function
    def read_binary_object_at(fname,fd,pos)
      position = @offsets[pos]
      fd.seek(position,IO::SEEK_SET)
      return read_binary_object(fname,fd)
    end
    protected :read_binary_object_at

    # calculate the bytes needed for a size integer value
    def Binary.bytes_size_int(int)
      nbytes = 0

      nbytes += 2 if int > 0xE # 2 bytes int
      nbytes += 2 if int > 0xFF # 3 bytes int
      nbytes += 2 if int > 0xFFFF # 5 bytes int

      return nbytes
    end

    # Calculate the byte needed for a „normal” integer value
    def Binary.bytes_int(int)
      nbytes = 1

      nbytes += 1 if int > 0xFF # 2 byte int
      nbytes += 2 if int > 0xFFFF # 4 byte int
      nbytes += 4 if int > 0xFFFFFFFF # 8 byte int
      nbytes += 7 if int < 0 # 8 byte int (since it is signed)

      return nbytes + 1 # one „marker” byte
    end

    # pack an +int+ of +nbytes+ with size
    def Binary.pack_it_with_size(nbytes,int)
      case nbytes
      when 1
        return [int].pack('c')
      when 2
        return [int].pack('n')
      when 4
        return [int].pack('N')
      when 8
        return [int >> 32, int & 0xFFFFFFFF].pack('NN')
      else
        raise CFFormatError.new("Don't know how to pack #{nbytes} byte integer")
      end
    end
    
    def Binary.pack_int_array_with_size(nbytes, array)
      case nbytes
      when 1
        array.pack('C*')
      when 2
        array.pack('n*')
      when 4
        array.pack('N*')
      when 8
        array.collect { |int| [int >> 32, int & 0xFFFFFFFF].pack('NN') }.join
      else
        raise CFFormatError.new("Don't know how to pack #{nbytes} byte integer")
      end
    end

    # calculate how many bytes are needed to save +count+
    def Binary.bytes_needed(count)
      if count < 2**8
        nbytes = 1
      elsif count < 2**16
        nbytes = 2
      elsif count < 2**32
        nbytes = 4
      elsif count < 2**64
        nbytes = 8
      else
        raise CFFormatError.new("Data size too large: #{count}")
      end

      return nbytes
    end

    # create integer bytes of +int+
    def Binary.int_bytes(int)
      intbytes = ""

      if(int > 0xFFFF) then
        intbytes = "\x12"+[int].pack("N") # 4 byte integer
      elsif(int > 0xFF) then
        intbytes = "\x11"+[int].pack("n") # 2 byte integer
      else
        intbytes = "\x10"+[int].pack("C") # 8 byte integer
      end

      return intbytes;
    end

    # Create a type byte for binary format as defined by apple
    def Binary.type_bytes(type,length)
      if length < 15
        return [(type << 4) | length].pack('C')
      else
        bytes = [(type << 4) | 0xF]
        if length <= 0xFF
          return bytes.push(0x10, length).pack('CCC')                              # 1 byte length
        elsif length <= 0xFFFF
          return bytes.push(0x11, length).pack('CCn')                              # 2 byte length
        elsif length <= 0xFFFFFFFF
          return bytes.push(0x12, length).pack('CCN')                              # 4 byte length
        elsif length <= 0x7FFFFFFFFFFFFFFF
          return bytes.push(0x13, length >> 32, length & 0xFFFFFFFF).pack('CCNN')  # 8 byte length
        else
          raise CFFormatError.new("Integer too large: #{int}")
        end
      end
    end



    # Counts the number of bytes the string will have when coded; utf-16be if non-ascii characters are present.
    def Binary.binary_strlen(val)
      val.each_byte do |b|
        if(b > 127) then
          val = Binary.charset_convert(val, 'UTF-8', 'UTF-16BE')
          return val.bytesize
        end
      end

      return val.bytesize
    end
    
    def count_object_refs(object)
      case object
      when CFArray
        contained_refs = 0
        object.value.each do |element|
          if CFArray === element || CFDictionary === element
            contained_refs += count_object_refs(element)
          end
        end
        return object.value.size + contained_refs
      when CFDictionary
        contained_refs = 0
        object.value.each_pair do |key, value|
          
          if value.nil?
            object.value.delete(key)
            next
          end
          
          if CFArray === value || CFDictionary === value
            contained_refs += count_object_refs(value)
          end
        end
        return object.value.keys.size * 2 + contained_refs
      else
        return 0
      end
    end

    def Binary.ascii_string?(str)
      if str.respond_to?(:ascii_only?)
        return str.ascii_only?
      else
        return str.scan(/[\x80-\xFF]/mn).size == 0
      end
    end

    # Uniques and transforms a string value to binary format and adds it to the object table
    def string_to_binary(val)
      saved_object_count = -1

      unless(@unique_table.has_key?(val)) then
        saved_object_count = @written_object_count
        @written_object_count += 1

        @unique_table[val] = saved_object_count
        utf16 = !Binary.ascii_string?(val)

        utf8_strlen = 0
        if(utf16) then
          utf8_strlen = Binary.charset_strlen(val, "UTF-8")
          val = Binary.charset_convert(val,"UTF-8","UTF-16BE")
          bdata = Binary.type_bytes(0b0110, Binary.charset_strlen(val,"UTF-16BE"))

          val.force_encoding("ASCII-8BIT") if val.respond_to?("encode")
          @object_table[saved_object_count] = bdata + val
        else
          utf8_strlen = val.bytesize
          bdata = Binary.type_bytes(0b0101,val.bytesize)
          @object_table[saved_object_count] = bdata + val
        end
      else
        saved_object_count = @unique_table[val]
      end

      return saved_object_count
    end

    # Codes an integer to binary format
    def int_to_binary(value)
      nbytes = 0
      nbytes = 1 if value > 0xFF # 1 byte integer
      nbytes += 1 if value > 0xFFFF # 4 byte integer
      nbytes += 1 if value > 0xFFFFFFFF # 8 byte integer
      nbytes = 3 if value < 0 # 8 byte integer, since signed

      bdata = Binary.type_bytes(0b0001, nbytes)
      buff = ""

      if(nbytes < 3) then
        fmt = "N"

        if(nbytes == 0) then
          fmt = "C"
        elsif(nbytes == 1)
          fmt = "n"
        end

        buff = [value].pack(fmt)
      else
        # 64 bit signed integer; we need the higher and the lower 32 bit of the value
        high_word = value >> 32
        low_word = value & 0xFFFFFFFF
        buff = [high_word,low_word].pack("NN")
      end

      return bdata + buff
    end

    # Codes a real value to binary format
    def real_to_binary(val)
      bdata = Binary.type_bytes(0b0010,3)
      buff = [val].pack("d")
      return bdata + buff.reverse
    end

    # Converts a numeric value to binary and adds it to the object table
    def num_to_binary(value)
      saved_object_count = @written_object_count
      @written_object_count += 1

      val = ""
      if(value.is_a?(CFInteger)) then
        val = int_to_binary(value.value)
      else
        val = real_to_binary(value.value)
      end

      @object_table[saved_object_count] = val
      return saved_object_count
    end

    # Convert date value (apple format) to binary and adds it to the object table
    def date_to_binary(val)
      saved_object_count = @written_object_count
      @written_object_count += 1

      val = val.getutc.to_f - CFDate::DATE_DIFF_APPLE_UNIX # CFDate is a real, number of seconds since 01/01/2001 00:00:00 GMT

      bdata = Binary.type_bytes(0b0011, 3)
      @object_table[saved_object_count] = bdata + [val].pack("d").reverse

      return saved_object_count
    end

    # Convert a bool value to binary and add it to the object table
    def bool_to_binary(val)
      saved_object_count = @written_object_count
      @written_object_count += 1

      @object_table[saved_object_count] = val ? "\x9" : "\x8" # 0x9 is 1001, type indicator for true; 0x8 is 1000, type indicator for false
      return saved_object_count
    end

    # Convert data value to binary format and add it to the object table
    def data_to_binary(val)
      saved_object_count = @written_object_count
      @written_object_count += 1

      bdata = Binary.type_bytes(0b0100, val.bytesize)
      @object_table[saved_object_count] = bdata + val

      return saved_object_count
    end

    # Convert array to binary format and add it to the object table
    def array_to_binary(val)
      saved_object_count = @written_object_count
      @written_object_count += 1

      bdata = Binary.type_bytes(0b1010, val.value.size) +
        Binary.pack_int_array_with_size(@object_ref_size, val.value.collect { |v| v.to_binary(self) })

      @object_table[saved_object_count] = bdata
      return saved_object_count
    end

    # Convert dictionary to binary format and add it to the object table
    def dict_to_binary(val)
      saved_object_count = @written_object_count
      @written_object_count += 1

      keys_and_values = val.value.keys.collect { |k| CFString.new(k).to_binary(self) }
      keys_and_values += val.value.keys.collect { |k| val.value[k].to_binary(self) }
      
      bdata = Binary.type_bytes(0b1101,val.value.size) +
        Binary.pack_int_array_with_size(@object_ref_size, keys_and_values)

      @object_table[saved_object_count] = bdata
      return saved_object_count
    end
  end
end

# eof
