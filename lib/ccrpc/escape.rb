# -*- coding: utf-8 -*-
# -*- frozen_string_literal: true -*-

module Ccrpc
  module Escape
    def self.escape(data)
      data = data.b if data.frozen? || data.encoding != Encoding::BINARY
      data.gsub(/([\a\n\t\\])/n){ "\\x" + $1.unpack("H2")[0] }
    end

    def self.unescape(data)
      data.b.gsub(/\\x([0-9a-fA-F]{2,2})/n){ [$1].pack("H*") }.force_encoding(Encoding::UTF_8)
    end
  end
end
