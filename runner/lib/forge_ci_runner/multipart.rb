# frozen_string_literal: true

require "securerandom"

module ForgeCIRunner
  # Streaming multipart/form-data request bodies from stdlib only.
  #
  # Files are streamed from disk in chunks and never fully buffered, which
  # matters for large cache tarballs. Works as a Net::HTTP body_stream:
  #
  #   body = Multipart::Body.new({ "key" => "bundle-v1" },
  #                              [{ name: "file", filename: "c.tgz", path: "/tmp/c.tgz" }])
  #   request["Content-Type"] = body.content_type
  #   request["Content-Length"] = body.size.to_s
  #   request.body_stream = body
  module Multipart
    class Body
      CHUNK = 65_536

      FilePart = Struct.new(:name, :filename, :path, :content_type, keyword_init: true)

      def initialize(fields, files)
        @boundary = "----ForgeCIRunner#{SecureRandom.hex(16)}"
        @fields = fields
        @files = files.map do |f|
          path = f[:path] || f["path"]
          FilePart.new(
            name: f[:name] || f["name"],
            filename: f[:filename] || f["filename"] || File.basename(path.to_s),
            path: path,
            content_type: f[:content_type] || f["content_type"] || "application/octet-stream"
          )
        end
        @size = compute_size
        reset
      end

      attr_reader :size

      def content_type
        "multipart/form-data; boundary=#{@boundary}"
      end

      def reset
        @parts = build_parts
        @file_io = nil
        self
      end

      # IO-like read for Net::HTTP body_stream. Returns nil at EOF.
      def read(length = nil, outbuf = +"")
        outbuf.clear
        want = length || CHUNK
        while outbuf.bytesize < want
          chunk = next_chunk(want - outbuf.bytesize)
          break if chunk.nil?

          outbuf << chunk
        end
        outbuf.empty? ? nil : outbuf
      end

      private

      def build_parts
        parts = []
        @fields.each do |name, value|
          parts << [:str, field_part(name, value).b]
        end
        @files.each do |f|
          parts << [:str, file_header(f).b]
          parts << [:file, f.path]
          parts << [:str, "\r\n".b]
        end
        parts << [:str, "--#{@boundary}--\r\n".b]
        parts
      end

      def field_part(name, value)
        "--#{@boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
      end

      def file_header(f)
        "--#{@boundary}\r\n" \
          "Content-Disposition: form-data; name=\"#{f.name}\"; filename=\"#{f.filename}\"\r\n" \
          "Content-Type: #{f.content_type}\r\n\r\n"
      end

      def compute_size
        total = 0
        @fields.each { |name, value| total += field_part(name, value).bytesize }
        @files.each do |f|
          total += file_header(f).bytesize
          total += File.size(f.path)
          total += "\r\n".bytesize
        end
        total + "--#{@boundary}--\r\n".bytesize
      end

      def next_chunk(max)
        if @file_io
          data = @file_io.read([max, CHUNK].min)
          if data.nil?
            @file_io.close
            @file_io = nil
          else
            return data.b
          end
        end
        return nil if @parts.empty?

        kind, payload = @parts.shift
        if kind == :str
          if payload.bytesize > max
            head = payload.byteslice(0, max)
            @parts.unshift([:str, payload.byteslice(max..)])
            head
          else
            payload
          end
        else
          @file_io = File.open(payload, "rb")
          next_chunk(max)
        end
      end
    end
  end
end
