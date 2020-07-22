# -*- coding: utf-8 -*-
# -*- frozen_string_literal: true -*-

module Ccrpc
  module Escape
    def self.escape(data)
      if data.encoding == Encoding::UTF_8 && data.valid_encoding?
        data.gsub(/\\/, "\\\\\\\\").gsub(/([^\u0020-\u007e\u0080-\uFFFF])/){ "\\x" + $1.unpack("H2")[0] }
      else
        data = data.encode(Encoding::UTF_8).force_encoding(Encoding::BINARY) unless data.encoding == Encoding::BINARY
        data.gsub(/([^\w ^+\-*\/#~\.])/){ "\\x" + $1.unpack("H2")[0] }
      end
    end

    def self.unescape(data)
      data.gsub(/\\x([0-9a-f]{2,2})|(\\\\)/i){ $2 ? "\\" : [$1].pack("H*") }.force_encoding(Encoding::UTF_8)
    end
  end
end
