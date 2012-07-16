# Author:: Couchbase <info@couchbase.com>
# Copyright:: 2011, 2012 Couchbase, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

module Couchbase

  class Bucket

    # Compare and swap value.
    #
    # @since 1.0.0
    #
    # Reads a key's value from the server and yields it to a block. Replaces
    # the key's value with the result of the block as long as the key hasn't
    # been updated in the meantime, otherwise raises
    # {Couchbase::Error::KeyExists}. CAS stands for "compare and swap", and
    # avoids the need for manual key mutexing. Read more info here:
    #
    # In asynchronous mode it will yield result twice, first for
    # {Bucket#get} with {Result#operation} equal to +:get+ and
    # second time for {Bucket#set} with {Result#operation} equal to +:set+.
    #
    # @see http://couchbase.com/docs/memcached-api/memcached-api-protocol-text_cas.html
    #
    # @param [String, Symbol] key
    #
    # @param [Hash] options the options for "swap" part
    # @option options [Fixnum] :ttl (self.default_ttl) the time to live of this key
    # @option options [Symbol] :format (self.default_format) format of the value
    # @option options [Fixnum] :flags (self.default_flags) flags for this key
    #
    # @yieldparam [Object, Result] value old value in synchronous mode and
    #   +Result+ object in asynchronous mode.
    # @yieldreturn [Object] new value.
    #
    # @raise [Couchbase::Error::KeyExists] if the key was updated before the the
    #   code in block has been completed (the CAS value has been changed).
    # @raise [ArgumentError] if the block is missing for async mode
    #
    # @example Implement append to JSON encoded value
    #
    #     c.default_format = :document
    #     c.set("foo", {"bar" => 1})
    #     c.cas("foo") do |val|
    #       val["baz"] = 2
    #       val
    #     end
    #     c.get("foo")      #=> {"bar" => 1, "baz" => 2}
    #
    # @example Append JSON encoded value asynchronously
    #
    #     c.default_format = :document
    #     c.set("foo", {"bar" => 1})
    #     c.run do
    #       c.cas("foo") do |val|
    #         case val.operation
    #         when :get
    #           val["baz"] = 2
    #           val
    #         when :set
    #           # verify all is ok
    #           puts "error: #{ret.error.inspect}" unless ret.success?
    #         end
    #       end
    #     end
    #     c.get("foo")      #=> {"bar" => 1, "baz" => 2}
    #
    # @return [Fixnum] the CAS of new value
    def cas(key, options = {})
      if async?
        block = Proc.new
        get(key) do |ret|
          val = block.call(ret) # get new value from caller
          set(ret.key, val, options.merge(:cas => ret.cas), &block)
        end
      else
        val, flags, ver = get(key, :extended => true)
        val = yield(val) # get new value from caller
        set(key, val, options.merge(:cas => ver))
      end
    end
    alias :compare_and_swap :cas

    # Fetch design docs stored in current bucket
    #
    # @since 1.2.0
    #
    # @return [Hash]
    def design_docs
      docs = all_docs(:startkey => "_design/", :endkey => "_design0", :include_docs => true)
      docmap = {}
      docs.each do |doc|
        key = doc.id.sub(/^_design\//, '')
        next if self.environment == :production && key =~ /dev_/
        docmap[key] = doc
      end
      docmap
    end

    # Fetch all documents from the bucket.
    #
    # @since 1.2.0
    #
    # @param [Hash] params Params for Couchbase +/_all_docs+ query
    #
    # @return [Couchbase::View] View object
    def all_docs(params = {})
      View.new(self, "_all_docs", params)
    end

    # Update or create design doc with supplied views
    #
    # @since 1.2.0
    #
    # @param [Hash, IO, String] data The source object containing JSON
    #   encoded design document. It must have +_id+ key set, this key
    #   should start with +_design/+.
    #
    # @return [true, false]
    def save_design_doc(data)
      attrs = case data
              when String
                MultiJson.load(data)
              when IO
                MultiJson.load(data.read)
              when Hash
                data
              else
                raise ArgumentError, "Document should be Hash, String or IO instance"
              end

      if attrs['_id'].to_s !~ /^_design\//
        raise ArgumentError, "'_id' key must be set and start with '_design/'."
      end
      attrs['language'] ||= 'javascript'
      req = make_couch_request(attrs['_id'],
                               :body => MultiJson.dump(attrs),
                               :method => :put)
      res = MultiJson.load(req.perform)
      if res['ok']
        true
      else
        raise "Failed to save design document: #{res['error']}"
      end
    end

    # Delete design doc with given id and revision.
    #
    # @since 1.2.0
    #
    # @param [String] id Design document id. It might have '_design/'
    #   prefix.
    #
    # @param [String] rev Document revision. It uses latest revision if
    #   +rev+ parameter is nil.
    #
    # @return [true, false]
    def delete_design_doc(id, rev = nil)
      ddoc = design_docs[id.sub(/^_design\//, '')]
      return nil unless ddoc
      path = Utils.build_query(ddoc['_id'], :rev => rev || ddoc['_rev'])
      req = make_couch_request(path, :method => :delete)
      res = MultiJson.load(req.perform)
      if res['ok']
        true
      else
        raise "Failed to save design document: #{res['error']}"
      end
    end

    def create_timer(interval, &block)
      Timer.new(self, interval, &block)
    end

    def create_periodic_timer(interval, &block)
      Timer.new(self, interval, :periodic => true, &block)
    end

  end

end
