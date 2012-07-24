module Bitcoin

  # Optional DSL to help create blocks and transactions.
  #
  # see also BlockBuilder, TxBuilder, TxInBuilder, TxOutBuilder, ScriptBuilder
  module Builder

    # build a Bitcoin::Protocol::Block matching the given +target+.
    # see BlockBuilder for details.
    def blk(target = "00".ljust(32, 'f'))
      c = BlockBuilder.new
      yield c
      c.block(target)
    end

    # build a Bitcoin::Protocol::Tx.
    # see TxBuilder for details.
    def tx
      c = TxBuilder.new
      yield c
      c.tx
    end

    # build a Bitcoin::Script.
    # see ScriptBuilder for details.
    def script
      c = ScriptBuilder.new
      yield c
      c.script
    end

    # DSL to create a Bitcoin::Protocol::Block used by Builder#blk.
    #  block = blk("00".ljust(32, 'f')) do |b|
    #    b.prev_block "\x00"*32
    #    b.tx do |t|
    #      t.input {|i| i.coinbase }
    #      t.output do |o|
    #        o.value 5000000000;
    #        o.script do |s|
    #          s.type :address
    #          s.recipient Bitcoin::Key.generate.addr
    #        end
    #      end
    #    end
    #  end
    class BlockBuilder

      def initialize
        @block = Bitcoin::P::Block.new(nil)
      end

      # specify block version. this is usually not necessary. defaults to 1.
      def version v
        @version = v
      end

      # set the hash of the previous block.
      def prev_block hash
        @prev_block = hash
      end

      # add transactions to the block (see TxBuilder).
      def tx
        c = TxBuilder.new
        yield c
        @block.tx << c.tx
      end

      # create the block according to values specified via DSL.
      def block target
        @block.ver = @version || 1
        @block.prev_block = [@prev_block].pack("H*").reverse
        @block.mrkl_root = @mrkl_root
        @block.time = Time.now.to_i
        @block.nonce = 0
        @block.mrkl_root = [Bitcoin.hash_mrkl_tree(@block.tx.map {|t|
              t.hash }).last].pack("H*").reverse
        find_hash(target)
        Bitcoin::P::Block.new(@block.to_payload)
      end

      private

      # increment nonce/time to find a block hash matching the +target+.
      def find_hash target
        @block.bits = Bitcoin.encode_compact_bits(target)
        t = Time.now
        @block.recalc_block_hash
        until @block.hash < target
          @block.nonce += 1
          @block.recalc_block_hash
          if @block.nonce == 100000
            if t
              tt = 1 / ((Time.now - t) / 100000) / 1000
              print "\r%.2f khash/s" % tt
            end
            t = Time.now
            @block.time = Time.now.to_i
            @block.nonce = 0
            $stdout.flush
          end
        end
      end

    end

    # DSL to create Bitcoin::Protocol::Tx used by Builder#tx.
    # tx = tx do |t|
    #   t.input do |i|
    #     i.prev_out prev_tx  # previous transaction
    #     i.prev_out_index 0  # index of previous output
    #     i.signature_key key # Bitcoin::Key used to sign the input
    #   end
    #   t.output do |o|
    #     o.value 12345 # 0.00012345 BTC
    #     o.script {|s| s.type :address; s.recipient key.addr }
    #   end
    # end
    class TxBuilder

      def initialize
        @tx = Bitcoin::P::Tx.new(nil)
        @tx.ver, @tx.lock_time = 1, 0
        @ins, @outs = [], []
      end

      # specify tx version. this is usually not necessary. defaults to 1.
      def version n
        @tx.ver = n
      end

      # specify tx lock_time. this is usually not necessary. defaults to 0.
      def lock_time n
        @tx.lock_time = n
      end

      # add an input to the transaction (see TxInBuilder).
      def input
        c = TxInBuilder.new
        yield c
        @ins << c
      end

      # add an output to the transaction (see TxOutBuilder).
      def output
        c = TxOutBuilder.new
        yield c
        @outs << c
      end

      # create the transaction according to values specified via DSL and sign inputs.
      def tx
        @ins.each {|i| @tx.add_in(i.txin) }
        @outs.each {|o| @tx.add_out(o.txout) }
        @ins.each_with_index do |inc, i|
          if @tx.in[i].coinbase?
            script_sig = [inc.coinbase_data].pack("H*")
            @tx.in[i].script_sig_length = script_sig.bytesize
            @tx.in[i].script_sig = script_sig
            next
          end
          prev_tx = inc.instance_variable_get(:@prev_out)
          sig_hash = @tx.signature_hash_for_input(i, prev_tx)
          sig = inc.key.sign(sig_hash)
          script_sig = Bitcoin::Script.to_signature_pubkey_script(sig, [inc.key.pub].pack("H*"))
          @tx.in[i].script_sig_length = script_sig.bytesize
          @tx.in[i].script_sig = script_sig
          raise "Signature error"  unless @tx.verify_input_signature(i, prev_tx)
        end
        Bitcoin::P::Tx.new(@tx.to_payload)
      end
    end

    # create a Bitcoin::Protocol::TxIn used by TxBuilder#input.
    #
    # inputs can be either 'coinbase', in which case they only need to specify #coinbase,
    # or they have to define a #prev_out, #prev_out_index and #signature key.
    class TxInBuilder
      attr_reader :key, :coinbase_data

      def initialize
        @txin = Bitcoin::P::TxIn.new
      end

      # previous transaction that contains the output we want to use.
      def prev_out tx
        @prev_out = tx
      end

      # index of the output in the #prev_out transaction.
      def prev_out_index i
        @prev_out_index = i
      end

      # specify sequence. this is usually not needed.
      def sequence s
        @sequence = s
      end

      # Bitcoin::Key used to sign the signature_hash for the input.
      # see Bitcoin::Script.signature_hash_for_input and Bitcoin::Key.sign.
      def signature_key key
        @key = key
      end

      # specify that this is a coinbase input. optionally set +data+.
      def coinbase data = nil
        @coinbase_data = data || OpenSSL::Random.random_bytes(32)
        @prev_out = nil
        @prev_out_index = 4294967295
      end

      # create the txin according to values specified via DSL
      def txin
        @txin.prev_out = (@prev_out ? @prev_out.binary_hash : "\x00"*32)
        @txin.prev_out_index = @prev_out_index
        @txin.sequence = @sequence || "\xff\xff\xff\xff"
        @txin
      end
    end

    # create a Bitcoin::Script used by TxOutBuilder#script.
    class ScriptBuilder
      attr_reader :script

      def initialize
        @type = :address
        @script = nil
      end

      # script type (:pubkey, :address/hash160, :multisig).
      def type type
        @type = type.to_sym
      end

      # recipient(s) of the script.
      # depending on the #type, either an address, hash160 pubkey, etc.
      def recipient *data
        @script = Bitcoin::Script.send("to_#{@type}_script", *data)
      end
    end

    # create a Bitcoin::Protocol::TxOut used by TxBuilder#output.
    class TxOutBuilder
      attr_reader :txout

      def initialize
        @txout = Bitcoin::P::TxOut.new
      end

      # set output value (in base units / "satoshis")
      def value value
        @txout.value = value
      end

      # add a script to the output (see ScriptBuilder).
      def script &block
        c = ScriptBuilder.new
        yield c
        @txout.pk_script = c.script
      end

    end

  end
end
