require 'helper'

HASH = {'short_message' => 'message', 'host' => 'localhost'}

RANDOM_DATA = ('A'..'Z').to_a

class TestNotifier < Test::Unit::TestCase
  should "allow access to host, port, max_chunk_size and default_options" do
    n = GELF::Notifier.new
    assert_equal ['localhost', 12201, 1420, {}], [n.host, n.port, n.max_chunk_size, n.default_options]
    n.host, n.port, n.max_chunk_size, n.default_options = 'graylog2.org', 7777, :lan, {:host => 'grayhost'}
    assert_equal ['graylog2.org', 7777, 8154, {'host' => 'grayhost'}], [n.host, n.port, n.max_chunk_size, n.default_options]
    n.max_chunk_size = 1337.1
    assert_equal 1337, n.max_chunk_size
  end

  context "with notifier with mocked sender" do
    setup do
      @notifier = GELF::Notifier.new('host', 12345)
      @sender = mock
      @notifier.instance_variable_set('@sender', @sender)
    end

    context "extract_hash" do
      should "check arguments" do
        assert_raise(ArgumentError) { @notifier.__send__(:extract_hash) }
        assert_raise(ArgumentError) { @notifier.__send__(:extract_hash, 1, 2, 3) }
        assert_raise(ArgumentError) { @notifier.__send__(:extract_hash, 1, lambda{ 'lambda' }) }
        assert_raise(ArgumentError) { @notifier.__send__(:extract_hash, lambda{ 'lambda' }, 2) }
        assert_raise(ArgumentError) { @notifier.__send__(:extract_hash, 1) { 'block' }         }
      end

      should "work with hash" do
        assert_equal HASH, @notifier.__send__(:extract_hash, HASH)
      end

      should "work with any object which responds to #to_hash" do
        o = Object.new
        o.expects(:to_hash).returns(HASH)
        assert_equal HASH, @notifier.__send__(:extract_hash, o)
      end

      should "work with exception with backtrace" do
        e = RuntimeError.new('message')
        e.set_backtrace(caller)
        hash = @notifier.__send__(:extract_hash, e)
        assert_equal 'RuntimeError: message', hash['short_message']
        assert_match /Backtrace/, hash['full_message']
      end

      should "work with exception without backtrace" do
        e = RuntimeError.new('message')
        hash = @notifier.__send__(:extract_hash, e)
        assert_match /Backtrace is not available/, hash['full_message']
      end

      should "work with exception and hash" do
        e, h = RuntimeError.new('message'), {'param' => 1, 'short_message' => 'will be hidden by exception'}
        hash = @notifier.__send__(:extract_hash, e, h)
        assert_equal 'RuntimeError: message', hash['short_message']
        assert_equal 1, hash['param']
      end

      should "work with plain text" do
        assert_equal 'message', @notifier.__send__(:extract_hash, 'message')['short_message']
      end

      should "work with plain text and hash" do
        assert_equal HASH, @notifier.__send__(:extract_hash, 'message', 'host' => 'localhost')
      end

      should "work with lambda" do
        assert_equal HASH, @notifier.__send__(:extract_hash, lambda { HASH } )
      end

      should "work with block" do
        assert_equal HASH, @notifier.__send__(:extract_hash) { HASH }
      end

      should "covert hash keys to strings" do
        hash = @notifier.__send__(:extract_hash, :short_message => :message)
        assert hash.has_key?('short_message')
        assert !hash.has_key?(:short_message)
      end

      should "not overwrite keys on convert" do
        assert_raise(ArgumentError) { @notifier.__send__(:extract_hash, :short_message => :message1, 'short_message' => 'message2') }
      end

      should "use default_options" do
        @notifier.default_options = {:file => 'somefile.rb', 'short_message' => 'will be hidden by explicit argument'}
        hash = @notifier.__send__(:extract_hash, HASH)
        assert_equal 'somefile.rb', hash['file']
        assert_not_equal 'will be hidden by explicit argument', hash['short_message']
      end

      should "be compatible with HoptoadNotifier" do
        # https://github.com/thoughtbot/hoptoad_notifier/blob/master/README.rdoc, section Going beyond exceptions
        hash = @notifier.__send__(:extract_hash, :error_class => 'Class', :error_message => 'Message')
        assert_equal 'Class: Message', hash['short_message']
      end

      should "detect and cache host" do
        Socket.expects(:gethostname).once.returns("localhost")
        2.times { @notifier.__send__(:extract_hash, 'short_message' => 'message') }
        assert_equal 'localhost', @notifier.default_options['host']
      end
    end

    context "datagrams_from_hash" do
      should "not split short data" do
        datagrams = @notifier.__send__(:datagrams_from_hash, HASH)
        assert_equal 1, datagrams.count
        assert_equal "\170\234", datagrams[0][0..1]
      end

      should "split long data" do
        srand(1) # for stable tests
        hash = HASH.merge('something' => (0..3000).map { RANDOM_DATA[rand(RANDOM_DATA.count)] }.join) # or it will be compressed too good
        datagrams = @notifier.__send__(:datagrams_from_hash, hash)
        assert_equal 2, datagrams.count
        assert_equal "\036\017", datagrams[0][0..1]
        assert_equal "\036\017", datagrams[1][0..1]
      end
    end

    context "local cache" do
      should "call send datagrams after each notify!" do
        @sender.expects(:send_datagrams).twice
        2.times { @notifier.notify!(HASH) }
      end

      context "with enabled caching" do
        setup do
          @notifier.cache_size = 3
        end

        should "not send datagram immediately after notify!" do
          @sender.expects(:send_datagrams).never
          2.times { @notifier.notify!(HASH) }
        end

        should "send datagrams when cache is full" do
          @sender.expects(:send_datagrams).once
          3.times { @notifier.notify!(HASH) }
        end

        should "send datagrams when cache size is reduced" do
          @sender.expects(:send_datagrams).once
          2.times { @notifier.notify!(HASH) }
          @notifier.cache_size = 1
        end

        context "and caching limit is disabled" do
          setup do
            @notifier.cache_size = 0
            5.times { @notifier.notify!(HASH) }
          end

          before_should "not send datagrams when caching limit is disabled" do
            @sender.expects(:send_datagrams).never
          end

          should "send datagrams on send_pending_notifications" do
            @sender.expects(:send_datagrams).once
            @notifier.send_pending_notifications
          end
        end
      end
    end

    context "logger compatibility" do
      context "call notify with overwritten severity" do
        should "for standard levels" do
          GELF::LEVELS.each do |k, v|
            hash = HASH.merge('severity' => -1)
            @notifier.expects(:notify).with { |hash| hash['severity'] == v }
            @notifier.__send__(k, hash)
          end
        end

        should "for extended levels" do
          GELF::LEVELS_EXT.each do |k, v|
            hash = HASH.merge('severity' => -1)
            @notifier.expects(:notify).with { |hash| hash['severity'] == GELF::LEVELS[v] }
            @notifier.__send__(k, hash)
          end
        end
      end
    end

    should "pass valid data to sender" do
      @sender.expects(:send_datagrams).with do |datagrams|
        datagrams.is_a?(Array) && datagrams[0].is_a?(String)
      end
      @notifier.notify!(HASH)
    end

    should "not rescue from invalid invocation of #notify!" do
      assert_raise(ArgumentError) { @notifier.notify!(:no_short_message => 'too bad') }
    end

    should "rescue from invalid invocation of #notify" do
      @notifier.expects(:notify!).with(instance_of(Hash)).raises(ArgumentError)
      @notifier.expects(:notify!).with(instance_of(ArgumentError))
      assert_nothing_raised { @notifier.notify(:no_short_message => 'too bad') }
    end
  end
end
